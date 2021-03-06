#!/bin/bash

# Files created by OpenDistroForElasticsearch should always be group writable too
umask 0002

if [[ "$(id -u)" == "0" ]]; then
    echo "Elasticsearch cannot run as root. Please start your container as another user."
    exit 1
fi

# Parse Docker env vars to customize Elasticsearch
#
# e.g. Setting the env var cluster.name=testcluster
#
# will cause Elasticsearch to be invoked with -Ecluster.name=testcluster
#
# see https://www.elastic.co/guide/en/elasticsearch/reference/current/settings.html#_setting_default_settings

declare -a es_opts

while IFS='=' read -r envvar_key envvar_value
do
    # Elasticsearch settings need to have at least two dot separated lowercase
    # words, e.g. `cluster.name`, except for `processors` which we handle
    # specially
    if [[ "$envvar_key" =~ ^[a-z0-9_]+\.[a-z0-9_]+ || "$envvar_key" == "processors" ]]; then
        if [[ ! -z $envvar_value ]]; then
          es_opt="-E${envvar_key}=${envvar_value}"
          es_opts+=("${es_opt}")
        fi
    fi
done < <(env)

# The virtual file /proc/self/cgroup should list the current cgroup
# membership. For each hierarchy, you can follow the cgroup path from
# this file to the cgroup filesystem (usually /sys/fs/cgroup/) and
# introspect the statistics for the cgroup for the given
# hierarchy. Alas, Docker breaks this by mounting the container
# statistics at the root while leaving the cgroup paths as the actual
# paths. Therefore, Elasticsearch provides a mechanism to override
# reading the cgroup path from /proc/self/cgroup and instead uses the
# cgroup path defined the JVM system property
# es.cgroups.hierarchy.override. Therefore, we set this value here so
# that cgroup statistics are available for the container this process
# will run in.
export ES_JAVA_OPTS="-Des.cgroups.hierarchy.override=/ $ES_JAVA_OPTS"


# Start up the elasticsearch and performance analyzer agent processes.
# When either of them halts, this script exits, or we receive a SIGTERM or SIGINT signal then we want to kill both these processes.

function terminateProcesses {
    if kill -0 $ES_PID >& /dev/null; then
        echo "Killing elasticsearch process $ES_PID"
        kill -TERM $ES_PID
        wait $ES_PID
    fi
    if kill -0 $PA_PID >& /dev/null; then
        echo "Killing performance analyzer process $PA_PID"
        kill -TERM $PA_PID
        wait $PA_PID
    fi
}

# Enable job control so we receive SIGCHLD when a child process terminates
set -m

# Make sure we terminate the child processes in the event of us received TERM (e.g. "docker container stop"), INT (e.g. ctrl-C), EXIT (this script terminates for an unexpected reason), or CHLD (one of the processes terminated unexpectedly)
trap terminateProcesses TERM INT EXIT CHLD

# Start elasticsearch
/usr/share/elasticsearch/bin/elasticsearch "${es_opts[@]}" &
ES_PID=$!

# Start performance analyzer agent
ES_HOME=/usr/share/elasticsearch /usr/share/elasticsearch/bin/performance-analyzer-agent-cli &
PA_PID=$!

# Wait for the child processes to terminate
wait $ES_PID
echo "Elasticsearch exited with code $?"
wait $PA_PID
echo "Performance analyzer exited with code $?"
