#!/bin/bash
#set -x #echo on

# code to ignore case restrictions
shopt -s nocasematch

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"

recommended_outdir() {
  if [ "$(uname -s)" == "Darwin" ]; then
    echo "/Users/$USER/cse220_home"
  else
    echo "/home/$USER/cse220_home"
  fi
}

die() {
  echo "Error: $1" >&2
  exit 1
}

normalize_dirpath() {
  local path="$1"
  while [[ "$path" != "/" && "$path" == */ ]]; do
    path="${path%/}"
  done
  printf '%s\n' "$path"
}

require_option_arg() {
  local option="$1"
  local value="$2"
  if [ -z "$value" ] || [[ "$value" == -* ]]; then
    die "Option '$option' requires an argument."
  fi
}

# help function
help()
{
  local example_outdir
  example_outdir="$(recommended_outdir)"
  echo "Usage: ./run.sh [ -h | --help ]
                [ -o | --outdir ]
                [ -b | --build]
                [ -t | --trace]
                [ -s | --scarab ]
                [ -e | --experiment ]
                [ -p | --plot ]
                [ -c | --cleanup]"
  echo
  echo "!! Modify 'apps.list' and '<experiment_name>.json' to specify the apps to build and Scarab parameters before run !!"
  echo "The entire process of simulating a data center workload is the following."
  echo "1) application setup by building a docker image (each directory represents an application group)"
  echo "2) collect traces with different simpoint workflows for trace-based simulation"
  echo "3) run Scarab simulation in different modes"
  echo "To perform the later step, the previous steps must be performed first, meaning all the necessary options should be set at the same time. However, you can only run earlier step(s) by unsetting the later steps for debugging purposes."

  echo "Options:"
  echo "h     Print this Help."
  echo "o     Absolute path to the host directory mounted as /home/\$USER inside the container. scarab and simulation outputs will be created there. Use a dedicated directory such as $example_outdir, not the scarab-infra repo root."
  echo "b     Build a docker image with application setup. 0: Run a container of existing docker image 1: Build cached image and run a container of the cached image, 2: Build a new image from the beginning and overwrite whatever image with the same name. e.g) -b 2"
  echo "t     Collect traces with different SimPoint workflows. 0: Do not collect traces, 1: Only collect traces without simpoint clustering, 2: Collect traces based on SimPoint workflow - post-processing (trace, collect fingerprints, do simpoint clustering). e.g) -t 2"
  echo "s     Scarab simulation mode. 0: No simulation 1: execution-driven simulation w/o SimPoint 2: trace-based simulation w/o SimPoint (-t should be 1 if no traces exist already in the container). 3: execution-driven simulation w/ SimPoint 4: trace-based simulation w/ SimPoint. 5: trace-based simulation w/o SimPoint with pt. cse220 uses 220. e.g) -s 4"
  echo "e     Experiment name. e.g.) -e exp2"
  echo "p     Plot figures by using <exp>.json. e.g.) -p 1"
  echo "c     Clean up all the containers/volumes after run. 0: No clean up 2: Clean up e.g) -c 1"
}

if [ "$#" -eq 0 ]; then
  help
  exit 0
fi

while [[ $# -gt 0 ]];
do
  case "$1" in
    -h | --help) # display help
      help
      exit 0
      ;;
    -o | --outdir) # output directory
      require_option_arg "$1" "${2-}"
      OUTDIR="$2"
      shift 2
      ;;
    --outdir=*)
      OUTDIR="${1#*=}"
      require_option_arg "--outdir" "$OUTDIR"
      shift
      ;;
    -b | --build) # build a docker image
      require_option_arg "$1" "${2-}"
      BUILD=$2
      shift 2
      ;;
    --build=*)
      BUILD="${1#*=}"
      require_option_arg "--build" "$BUILD"
      shift
      ;;
    -t | --trace) # collect traces with simpoint workflows
      require_option_arg "$1" "${2-}"
      SIMPOINT=$2
      shift 2
      ;;
    --trace=*)
      SIMPOINT="${1#*=}"
      require_option_arg "--trace" "$SIMPOINT"
      shift
      ;;
    -s | --scarab) # scarab simulation mode
      require_option_arg "$1" "${2-}"
      SCARABMODE=$2
      shift 2
      ;;
    --scarab=*)
      SCARABMODE="${1#*=}"
      require_option_arg "--scarab" "$SCARABMODE"
      shift
      ;;
    -e | --experiment) # experiment name
      require_option_arg "$1" "${2-}"
      EXPERIMENT=$2
      shift 2
      ;;
    --experiment=*)
      EXPERIMENT="${1#*=}"
      require_option_arg "--experiment" "$EXPERIMENT"
      shift
      ;;
    -p | --plot) # plot figures
      require_option_arg "$1" "${2-}"
      PLOT=$2
      shift 2
      ;;
    --plot=*)
      PLOT="${1#*=}"
      require_option_arg "--plot" "$PLOT"
      shift
      ;;
    -c | --cleanup) # clean up the containers
      require_option_arg "$1" "${2-}"
      CLEANUP=$2
      shift 2
      ;;
    --cleanup=*)
      CLEANUP="${1#*=}"
      require_option_arg "--cleanup" "$CLEANUP"
      shift
      ;;
    --)
      shift
      break
      ;;
    *) # unexpected option
      if [[ "$1" == -* ]]; then
        die "Unexpected option: $1"
      fi
      die "Unexpected argument: $1"
      ;;
  esac
done

RECOMMENDED_OUTDIR="$(recommended_outdir)"

if [ $# -gt 0 ]; then
  die "Unexpected argument: $1"
fi

if [ -z "$OUTDIR" ]; then
  die "The output directory path should be provided. Use a dedicated Docker home directory such as '$RECOMMENDED_OUTDIR'."
fi

OUTDIR="$(normalize_dirpath "$OUTDIR")"
REPO_ROOT="$(normalize_dirpath "$REPO_ROOT")"

case "$OUTDIR" in
  /*) ;;
  *)
    die "The -o/--outdir path must be absolute. Use a dedicated Docker home directory such as '$RECOMMENDED_OUTDIR'."
    ;;
esac

if [ "$OUTDIR" == "$REPO_ROOT" ]; then
  die "Do not use the scarab-infra repo root as -o/--outdir. Use a dedicated Docker home directory such as '$RECOMMENDED_OUTDIR'. The -o path is mounted as /home/$USER inside the container."
fi

if [ "$SCARABMODE" == "220" ] && [ -z "$BUILD" ]; then
  EXPECTED_CONTAINER="cse220_$USER"
  if ! docker container inspect "$EXPECTED_CONTAINER" >/dev/null 2>&1; then
    die "Scarab mode 220 expects the standard container '$EXPECTED_CONTAINER'. Run './run.sh -o $RECOMMENDED_OUTDIR -b 2' first."
  fi
  if [ ! -d "$OUTDIR/scarab" ]; then
    die "Scarab mode 220 expects '$OUTDIR/scarab' to exist. This directory is created by the build step. Run './run.sh -o $RECOMMENDED_OUTDIR -b 2' first."
  fi
fi

mkdir -p "$OUTDIR"

source utilities.sh

# build docker images and start containers
echo "build docker images and start containers.."
taskPids=()
start=`date +%s`
while read APPNAME ;do
  source setup_apps.sh

  if [ -n "$BUILD" ]; then
    source build_apps.sh || exit $?
  fi

  if [ -n "$SIMPOINT" ]; then
    if [ "$APPNAME" == "allbench" ]; then
      echo "allbench is only for trace-based simulations with the traces from UCSC NFS"
      exit 1
    fi
    CONTAINER_NAME="${APP_GROUPNAME}_$USER"
    # run simpoint/trace
    echo "run simpoint/trace.."

    # tokenize multiple environment variables
    ENVVARS=""
    echo $ENVVARS
    for token in $ENVVAR;
    do
       ENVVARS+=" -e ";
       ENVVARS+=$token;
    done

    # update the script
    docker cp ./run_simpoint_trace.sh "$CONTAINER_NAME":/usr/local/bin
    docker exec $ENVVARS --user $USER --workdir /home/$USER --privileged "$CONTAINER_NAME" run_simpoint_trace.sh "$APPNAME" "$APP_GROUPNAME" "$BINCMD" "$SIMPOINT" "$DRIO_ARGS" &
    sleep 2
    while read -r line ;do
      IFS=" " read PID CMD <<< $line
      if [ "$CMD" == "/bin/bash /usr/local/bin/run_simpoint_trace.sh $APPNAME $APP_GROUPNAME $BINCMD $SIMPOINT $DRIO_ARGS" ]; then
        taskPids+=($PID)
      fi
    done < <(docker top "$CONTAINER_NAME" -eo pid,cmd)
  fi
done < apps.list

wait_for_non_child "simpoint/tracing" "${taskPids[@]}"
end=`date +%s`
report_time "post-processing" "$start" "$end"

if [ -n "$SCARABMODE" ]; then
  # run Scarab simulation
  echo "run Scarab simulation.."
  taskPids=()
  start=`date +%s`

  while read APPNAME; do
    source setup_apps.sh
    CONTAINER_NAME="${APP_GROUPNAME}_$USER"
    # update the script
    if [ "$APP_GROUPNAME" == "cse220" ]; then
      docker cp ./$APP_GROUPNAME/run_exp_using_descriptor.py "$CONTAINER_NAME":/usr/local/bin
      docker cp ./$APP_GROUPNAME/run_cse220.sh "$CONTAINER_NAME":/usr/local/bin
    else
      docker cp ./run_exp_using_descriptor.py "$CONTAINER_NAME":/usr/local/bin
    fi
    if [ "$APP_GROUPNAME" == "allbench_traces" ]; then
      cp "${EXPERIMENT}.json" "$OUTDIR"
      docker exec --user $USER --workdir /home/$USER --privileged "$CONTAINER_NAME" python3 /usr/local/bin/run_exp_using_descriptor.py -d $EXPERIMENT.json -a $APPNAME -g $APP_GROUPNAME -m $SCARABMODE &
      while read -r line; do
        IFS=" " read PID CMD <<< $line
        if [ "$CMD" == "python3 /usr/local/bin/run_exp_using_descriptor.py -d $EXPERIMENT.json -a $APPNAME -g $APP_GROUPNAME -m $SCARABMODE" ]; then
          taskPids+=($PID)
        fi
      done < <(docker top "$CONTAINER_NAME" -eo pid,cmd)
    elif [ "$APP_GROUPNAME" == "isca2024_udp" ] || [ "$APP_GROUPNAME" == "docker_traces" ] || [ "$APP_GROUPNAME" == "cse220" ]; then
      cp "${APP_GROUPNAME}/${EXPERIMENT}.json" "$OUTDIR"
      docker exec --user $USER --workdir /home/$USER --privileged "$CONTAINER_NAME" python3 /usr/local/bin/run_exp_using_descriptor.py -d $EXPERIMENT.json -a $APPNAME -g $APP_GROUPNAME -m $SCARABMODE &
      while read -r line; do
        IFS=" " read PID CMD <<< $line
        if [ "$CMD" == "python3 /usr/local/bin/run_exp_using_descriptor.py -d $EXPERIMENT.json -a $APPNAME -g $APP_GROUPNAME -m $SCARABMODE" ]; then
          taskPids+=($PID)
        fi
      done < <(docker top "$CONTAINER_NAME" -eo pid,cmd)
    else
      cp "${EXPERIMENT}.json" "$OUTDIR"
      docker exec --user $USER --workdir /home/$USER --privileged "$CONTAINER_NAME" python3 /usr/local/bin/run_exp_using_descriptor.py -d $EXPERIMENT.json -a $APPNAME -g $APP_GROUPNAME -c $BINCMD -m $SCARABMODE &
      while read -r line; do
        IFS=" " read PID CMD <<< $line
        if [ "$CMD" == "python3 /usr/local/bin/run_exp_using_descriptor.py -d $EXPERIMENT.json -a $APPNAME -g $APP_GROUPNAME -c $BINCMD -m $SCARABMODE" ]; then
          taskPids+=($PID)
        fi
      done < <(docker top "$CONTAINER_NAME" -eo pid,cmd)
    fi
  done < apps.list

  wait_for_non_child "Scarab-simulation" "${taskPids[@]}"
  end=`date +%s`
  report_time "Scarab-simulation" "$start" "$end"
fi

if [ -n "$PLOT" ]; then
  # plot figures by using json exp descriptor
  echo "plot figures.."
  taskPids=()
  start=`date +%s`

  while read APPNAME; do
    source setup_apps.sh
    CONTAINER_NAME="${APP_GROUPNAME}_$USER"
    # update the script
    if [ "$APP_GROUPNAME" == "cse220" ]; then
      docker cp ./$APP_GROUPNAME/plot/. "$CONTAINER_NAME":/usr/local/bin/plot
    else
      docker cp ./plot/. "$CONTAINER_NAME":/usr/local/bin/plot
    fi
    cp "${APP_GROUPNAME}/${EXPERIMENT}.json" "$OUTDIR"
    docker exec --user $USER --env USER=$USER --env EXPERIMENT=$EXPERIMENT --workdir /home/$USER --privileged "$CONTAINER_NAME" /bin/bash /usr/local/bin/plot/plot_figures.sh
  done < apps.list
fi

if [ -n "$CLEANUP" ]; then
  echo "clean up the containers.."
  # solr requires extra cleanup
  taskPids=()
  start=`date +%s`
  while read APPNAME ;do
    source setup_apps.sh
    CONTAINER_NAME="${APP_GROUPNAME}_$USER"
    case $APPNAME in
      solr)
        rmCmd="docker rm web_search_client"
        eval $rmCmd &
        taskPids+=($!)
        sleep 2
        ;;
    esac
    docker stop "$CONTAINER_NAME"
    rmCmd="docker rm $CONTAINER_NAME"
    eval $rmCmd &
    taskPids+=($!)
    sleep 2
  done < apps.list

  wait_for "container-cleanup" "${taskPids[@]}"
  end=`date +%s`
  report_time "container-cleanup" "$start" "$end"

  echo "clean up the volumes.."
  # remove docker volume
  taskPids=()
  start=`date +%s`
  while read APPNAME ; do
    source setup_apps.sh
    rmCmd="docker volume rm $APP_GROUPNAME"
    eval $rmCmd &
    taskPids+=($!)
    sleep 2
  done < apps.list

  wait_for "volume-cleanup" "${taskPids[@]}"
  end=`date +%s`
  report_time "volume-cleanup" "$start" "$end"
fi
