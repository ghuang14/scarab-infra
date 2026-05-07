LOCAL_UID=$(id -u $USER)
LOCAL_GID=$(id -g $USER)
USER_ID=${LOCAL_UID:-9001}
GROUP_ID=${LOCAL_GID:-9001}

DOCKER_PLATFORM_ARGS=()
if [ "$(uname -s)" == "Darwin" ]; then
  # Docker Desktop on Apple Silicon should use amd64 for Pin/Scarab tooling.
  DOCKER_PLATFORM_ARGS=(--platform linux/amd64)
fi

run_step() {
  "$@"
  local status=$?
  if [ $status -ne 0 ]; then
    return $status
  fi
}

is_positive_int() {
  case "$1" in
    ''|*[!0-9]*|0)
      return 1
      ;;
    *)
      return 0
      ;;
  esac
}

detect_scarab_build_jobs() {
  if is_positive_int "${SCARAB_BUILD_JOBS:-}"; then
    printf '%s\n' "$SCARAB_BUILD_JOBS"
    return 0
  fi

  local cpu_count=2
  if command -v getconf >/dev/null 2>&1; then
    cpu_count="$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '2')"
  elif command -v nproc >/dev/null 2>&1; then
    cpu_count="$(nproc 2>/dev/null || printf '2')"
  fi

  if ! is_positive_int "$cpu_count"; then
    cpu_count=2
  fi

  if [ "$(uname -s)" == "Darwin" ]; then
    # Docker Desktop tends to run out of memory before CPU on Scarab's DynamoRIO build.
    if [ "$cpu_count" -gt 2 ]; then
      cpu_count=2
    fi
  elif [ "$cpu_count" -gt 4 ]; then
    cpu_count=4
  fi

  printf '%s\n' "$cpu_count"
}

patch_scarab_makefile_in_container() {
  local jobs="$1"
  local makefile="/home/$USER/scarab/src/Makefile"

  run_step docker exec --privileged "$CONTAINER_NAME" \
    env SCARAB_PATCH_JOBS="$jobs" perl -0pi -e '
    my $jobs = $ENV{SCARAB_PATCH_JOBS};
    s/^SCARAB_MAKE_JOBS \?= .*$/SCARAB_MAKE_JOBS ?= $jobs/m
      or s/^(BUILD_DIR_PREFIX = build\n)/$1\nSCARAB_MAKE_JOBS ?= $jobs\n/m;
    s/^SCARAB_CMAKE_ARGS \?= .*$/SCARAB_CMAKE_ARGS ?= -DSCARAB_ENABLE_LTO=OFF/m
      or s/^(SCARAB_MAKE_JOBS \?= .*\n)/$1SCARAB_CMAKE_ARGS ?= -DSCARAB_ENABLE_LTO=OFF\n/m;
    s/^\tmake --no-print-directory -j all$/\t\$(MAKE) --no-print-directory -j\$(SCARAB_MAKE_JOBS) all/m;
    s/^\t\@make -j --no-print-directory -C \$\(dir \$@\)$/\t\@\$(MAKE) -j\$(SCARAB_MAKE_JOBS) --no-print-directory -C \$(dir \$@)/m;
    s/^(\t\s*\$\(CMAKE\) \.\.\/\.\. -DCMAKE_BUILD_TYPE=\$\(BUILD_TYPE\))(?:\s+\$\(SCARAB_CMAKE_ARGS\))?$/\1 \$(SCARAB_CMAKE_ARGS)/m;
  ' "$makefile"
  run_step docker exec --privileged "$CONTAINER_NAME" chown "$USER_ID:$GROUP_ID" "$makefile"
}

build_scarab_in_container() {
  patch_scarab_makefile_in_container "$SCARAB_BUILD_JOBS_LIMIT" || return $?
  echo "building scarab with $SCARAB_BUILD_JOBS_LIMIT parallel job(s).."
  run_step docker exec --user="$USER" --privileged "$CONTAINER_NAME" /bin/bash -c "set -e; cmake_bin=\$(command -v cmake3 || command -v cmake); cd /home/$USER/scarab/src && make clean && make CMAKE=\"\$cmake_bin\" SCARAB_MAKE_JOBS=$SCARAB_BUILD_JOBS_LIMIT SCARAB_CMAKE_ARGS=-DSCARAB_ENABLE_LTO=OFF" || return $?
}

SCARAB_BUILD_JOBS_LIMIT="$(detect_scarab_build_jobs)"

CONTAINER_NAME="${APP_GROUPNAME}_$USER"

# A fresh rebuild should replace any prior container using the same mounted home.
if [ "$BUILD" == "2" ] && docker container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
  run_step docker rm -f "$CONTAINER_NAME" || return $?
fi

# build from the beginning and overwrite whatever image with the same name
if [ "$BUILD" == "2" ]; then
  run_step docker build "${DOCKER_PLATFORM_ARGS[@]}" . -f "./$APP_GROUPNAME/Dockerfile" --no-cache -t "$APP_GROUPNAME:latest" || return $?
elif [ "$BUILD" == "1" ]; then # find the existing cache/image and start from there
  run_step docker build "${DOCKER_PLATFORM_ARGS[@]}" . -f "./$APP_GROUPNAME/Dockerfile" -t "$APP_GROUPNAME:latest" || return $?
fi

# create volume for the app group
#docker volume create $APP_GROUPNAME

mkdir -p $OUTDIR/.ssh
cp ~/.ssh/id_rsa $OUTDIR/.ssh/id_rsa
# start container
case $APP_GROUPNAME in
  solr)
    # solr requires the host machine to download the data (14GB) from cloudsuite by first running "docker run --name web_search_dataset cloudsuite/web-search:dataset" once
    if [ $( docker ps -a -f name=web_search_dataset | wc -l ) -eq 2 ]; then
      echo "dataset exists"
    else
      echo "dataset does not exist, downloading"
      run_step docker run --name web_search_dataset cloudsuite/web-search:dataset || return $?
    fi
    # must mount dataset volume for server and docker to start querying
    run_step docker exec -it --privileged "$CONTAINER_NAME" /bin/bash -c "/usr/local/bin/entrypoint.sh" || return $?
	    run_step docker exec -it -d --privileged "$CONTAINER_NAME" /bin/bash -c '(docker run -it --name web_search_client --net host cloudsuite/web-search:client $(hostname -I) 10; pkill java)' || return $?
	    run_step docker run "${DOCKER_PLATFORM_ARGS[@]}" -e user_id=$USER_ID -e group_id=$GROUP_ID -e username=$USER -e HOME=/home/$USER -dit --privileged --name "$CONTAINER_NAME" --mount type=bind,source=$OUTDIR,target=/home/$USER $APP_GROUPNAME:latest /bin/bash || return $?
	    run_step docker start "$CONTAINER_NAME" || return $?
	    run_step docker exec --privileged "$CONTAINER_NAME" /bin/bash -c "/usr/local/bin/common_entrypoint.sh" || return $?
	    build_scarab_in_container || return $?
	    ;;
  spec2017)
	    run_step docker run "${DOCKER_PLATFORM_ARGS[@]}" -e user_id=$USER_ID -e group_id=$GROUP_ID -e username=$USER -e HOME=/home/$USER -dit --privileged --name "$CONTAINER_NAME" --mount type=bind,source=$OUTDIR,target=/home/$USER $APP_GROUPNAME:latest /bin/bash || return $?
	    run_step docker start "$CONTAINER_NAME" || return $?
	    run_step docker exec --privileged "$CONTAINER_NAME" /bin/bash -c "/usr/local/bin/common_entrypoint.sh" || return $?
	    build_scarab_in_container || return $?
	    run_step docker exec --privileged "$CONTAINER_NAME" /bin/bash -c "\$tmpdir/entrypoint.sh" || return $?
	    run_step docker exec --user=$USER --privileged "$CONTAINER_NAME" /bin/bash -c "\$tmpdir/install.sh" || return $?
	    ;;
  sysbench)
	    run_step docker run "${DOCKER_PLATFORM_ARGS[@]}" -e user_id=$USER_ID -e group_id=$GROUP_ID -e username=$USER -e HOME=/home/$USER -dit --privileged --name "$CONTAINER_NAME" --mount type=bind,source=$OUTDIR,target=/home/$USER $APP_GROUPNAME:latest /bin/bash || return $?
	    run_step docker start "$CONTAINER_NAME" || return $?
	    run_step docker exec --privileged "$CONTAINER_NAME" /bin/bash -c "/usr/local/bin/common_entrypoint.sh" || return $?
	    build_scarab_in_container || return $?
	    run_step docker exec --privileged "$CONTAINER_NAME" /bin/bash -c "/usr/local/bin/entrypoint.sh \"$APPNAME\"" || return $?
	    ;;
  allbench_traces)
	    run_step docker run "${DOCKER_PLATFORM_ARGS[@]}" -e user_id=$USER_ID -e group_id=$GROUP_ID -e username=$USER -e HOME=/home/$USER -dit --privileged --name "$CONTAINER_NAME" --mount type=bind,source=/soe/hlitz/lab/traces,target=/simpoint_traces,readonly --mount type=bind,source=$OUTDIR,target=/home/$USER $APP_GROUPNAME:latest /bin/bash || return $?
	    run_step docker start "$CONTAINER_NAME" || return $?
	    run_step docker exec --privileged "$CONTAINER_NAME" /bin/bash -c "/usr/local/bin/common_entrypoint.sh" || return $?
	    build_scarab_in_container || return $?
	    ;;
  isca2024_udp)
	    run_step docker run "${DOCKER_PLATFORM_ARGS[@]}" -e user_id=$USER_ID -e group_id=$GROUP_ID -e username=$USER -e HOME=/home/$USER -dit --privileged --name "$CONTAINER_NAME" --mount type=bind,source=$OUTDIR,target=/home/$USER $APP_GROUPNAME:latest /bin/bash || return $?
	    run_step docker start "$CONTAINER_NAME" || return $?
	    run_step docker exec --privileged "$CONTAINER_NAME" /bin/bash -c "/usr/local/bin/entrypoint.sh" || return $?
	    build_scarab_in_container || return $?
	    ;;
  cse220)
	    run_step docker run "${DOCKER_PLATFORM_ARGS[@]}" -e user_id=$USER_ID -e group_id=$GROUP_ID -e username=$USER -e HOME=/home/$USER -dit --privileged --name "$CONTAINER_NAME" --mount type=bind,source=$OUTDIR,target=/home/$USER $APP_GROUPNAME:latest /bin/bash || return $?
	    run_step docker start "$CONTAINER_NAME" || return $?
	    run_step docker exec --privileged "$CONTAINER_NAME" /bin/bash -c "/usr/local/bin/entrypoint.sh" || return $?
	    build_scarab_in_container || return $?
	    ;;
  docker_traces)
	    run_step docker run "${DOCKER_PLATFORM_ARGS[@]}" -e user_id=$USER_ID -e group_id=$GROUP_ID -e username=$USER -e HOME=/home/$USER -dit --privileged --name "$CONTAINER_NAME" --mount type=bind,source=$OUTDIR,target=/home/$USER $APP_GROUPNAME:latest /bin/bash || return $?
	    run_step docker start "$CONTAINER_NAME" || return $?
	    run_step docker exec --privileged "$CONTAINER_NAME" /bin/bash -c "/usr/local/bin/entrypoint.sh" || return $?
	    build_scarab_in_container || return $?
	    ;;
  example)
	    run_step docker run "${DOCKER_PLATFORM_ARGS[@]}" -e user_id=$USER_ID -e group_id=$GROUP_ID -e username=$USER -e HOME=/home/$USER -dit --privileged --name "$CONTAINER_NAME" --mount type=bind,source=$OUTDIR,target=/home/$USER $APP_GROUPNAME:latest /bin/bash || return $?
	    run_step docker start "$CONTAINER_NAME" || return $?
	    run_step docker exec --privileged "$CONTAINER_NAME" /bin/bash -c "/usr/local/bin/common_entrypoint.sh" || return $?
	    build_scarab_in_container || return $?
	    run_step docker exec --user=$USER --privileged "$CONTAINER_NAME" /bin/bash -c "cd /home/$USER/scarab/utils/qsort && make test_qsort" || return $?
	    ;;
  *)
	    run_step docker run "${DOCKER_PLATFORM_ARGS[@]}" -e user_id=$USER_ID -e group_id=$GROUP_ID -e username=$USER -e HOME=/home/$USER -dit --privileged --name "$CONTAINER_NAME" --mount type=bind,source=$OUTDIR,target=/home/$USER $APP_GROUPNAME:latest /bin/bash || return $?
	    run_step docker start "$CONTAINER_NAME" || return $?
	    run_step docker exec --privileged "$CONTAINER_NAME" /bin/bash -c "/usr/local/bin/common_entrypoint.sh" || return $?
	    build_scarab_in_container || return $?
	    ;;
esac

# Build scarab
