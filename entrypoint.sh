#!/bin/bash

_pipework_image_name="local/pipework:2.0"
_global_vars="run_mode host_routes host_route_arping host_route_protocols up_time key cmd sleep debug event_filters cleanup_wait retry_delay inter_delay route_add_delay"

for _var in $_global_vars; do
    _value="$(eval echo \$${_var})"
    [ "$_value" ] || _value="$(eval echo \$pipework_${_var})"
    eval "_pipework_${_var}=\"${_value}\""
done

[ "$_pipework_debug" ] && _debug="sh -x" && set -x
[ "$_pipework_sleep" ] && sleep $_pipework_sleep
[ "$_pipework_host_route_protocols" ] || _pipework_host_route_protocols="inet"

# _default_cleanup_wait="22" # for dhclient
_default_cleanup_wait="0" # for dhcp default busybox udhcpc
_pipework="$_debug /sbin/pipework"
_args="$@"

#export DOCKER_HOST=${DOCKER_HOST:-"unix:///docker.sock"}
_test_docker ()
{
	# Test for docker socket and client
	if ! docker -D info > /docker_info; then
        echo "error: can't connect to $DOCKER_HOST"
		exit 1
	fi
}

_cleanup ()
{
    [ "$_while_read_pid" ]     && kill  $_while_read_pid
    [ "$_docker_events_pid" ]  && kill  $_docker_events_pid
    [ "$_tail_f_pid" ]         && kill  $_tail_f_pid
    [ "$_docker_events_log" ]  && rm -f $_docker_events_log
    exit 0
}
trap _cleanup TERM INT QUIT HUP

_expand_macros ()
{
    for _macro in $_macros; do
        case $_macro in

            @CONTAINER_NAME@)
            name="$(docker inspect -f {{.Name}} ${c12id})"
            _pipework_vars="$(echo "$_pipework_vars" | sed -e "s|@CONTAINER_NAME@|${name#/}|g")"
            ;;

            @CONTAINER_ID@)
            _pipework_vars="$(echo "$_pipework_vars" | sed -e "s|@CONTAINER_ID@|$c12id|g")"
            ;;

            @HOSTNAME@)
            hostname="$(docker inspect -f '{{.Config.Hostname}}' "$c12id")"
            _pipework_vars="$(echo "$_pipework_vars" | sed -e "s|@HOSTNAME@|$hostname|g")"
            ;;

            @INSTANCE@)
            instance="$(docker inspect -f {{.Name}} ${c12id} | grep -o -e '[0-9]*' | tail -1)"
            _pipework_vars="$(echo "$_pipework_vars" | sed -e "s|@INSTANCE@|${instance}|g")"
            ;;

            @COMPOSE_PROJECT_NAME@)
            projectname="$(docker inspect   --format "{{ index .Config.Labels \"com.docker.compose.project\"}}" ${c12id})"
            _pipework_vars="$(echo "$_pipework_vars" | sed -e "s|@COMPOSE_PROJECT_NAME@|${projectname}|g")"
            ;;
        esac
    done
}

_docker_pid ()
{
    exec docker inspect --format '{{ .State.Pid }}' "$@"
}

_decrement_ipv4 ()
{
    ipv4_address_spaced="$(echo "$1" | tr . ' ')"
    ipv4_address_hex="$(printf "%02x%02x%02x%02x\n" $ipv4_address_spaced)"
    ipv4_address_uint32="$(printf "%u\n" 0x${ipv4_address_hex})"
    ipv4_address="$(printf "obase=256\n$(expr $ipv4_address_uint32 - 1)\n" | bc | tr ' ' . | cut -c2- | sed -e 's/255/254/g')"
    [ "$ipv4_address" != "${ipv4_address%.000}" ] && _decrement_ipv4 "$ipv4_address" "quiet"
    [ "$2" = "quiet" ] || printf "$ipv4_address\n"
}

_decrement_ipv6 ()
{
    ipv6_address_hex="$(echo "$1" | tr -d '\t :' | tr '[:lower:]' '[:upper:]')"

    # echo "echo \"obase=16;ibase=16; $ipv6_address_hex - 1;\" | bc"
    # echo "obase=16;ibase=16; $ipv6_address_hex - 1;" | bc

    ipv6_address_hex="$(echo "obase=16;ibase=16; $ipv6_address_hex - 1;" | bc)"
    padding="$(expr 32 - $(echo -n "$ipv6_address_hex" | wc -c))"

    if [ "$padding" -gt "0" ]; then
        ipv6_address_hex="$(printf "%0${padding}x${ipv6_address_hex}\n" | sed 's/.\{4\}/&:/g')"
    else
        ipv6_address_hex="$(printf "${ipv6_address_hex}\n" | sed 's/.\{4\}/&:/g')"
    fi

    printf "${ipv6_address_hex%:}\n"
}

_create_host_route ()
{
    c12id="$1" ; pipework_cmd="$2"
    set $pipework_cmd ; unset _arping

    if [ "$_pipework_host_route_arping" ] || [ "$pipework_host_route_arping" ]; then
        _arping=true
    fi

    [ "$2" = "-i" ] && cont_if="$3" || \
    cont_if="eth1"
    host_if="$1"

    _pid="$(_docker_pid $c12id)"

    # Apache 2.0 License, Credit @ jpetazzino
    # https://github.com/jpetazzo/pipework/blob/master/pipework#L201-203
    [ ! -d /var/run/netns ] && mkdir -p /var/run/netns
    [ -f /var/run/netns/$_pid ] && rm -f /var/run/netns/$_pid
    ln -s /proc/${_pid}/ns/net /var/run/netns/$_pid

    for proto in $_pipework_host_route_protocols; do
        ip_and_netmask="$(ip netns exec $_pid ip -o -f $proto addr show $cont_if | tr -s ' ' | cut -d ' ' -f4)"

        [ "$ip_and_netmask" ] || continue
        ip="$(echo "$ip_and_netmask" |  cut -d/ -f1)"
        netmask="$(echo "$ip_and_netmask" |  cut -d/ -f2)"

        case $proto in
            inet)
                unset last_ip
                if [ "$_debug" ]; then
                    fping -c1 -t200 $ip && continue
                    [ "$_arping" ] && arping -c1 -I $host_if $ip && continue
                else
                    fping -c1 -t200 $ip 2> /dev/null 1> /dev/null && continue
                    [ "$_arping" ] && arping -c1 -I $host_if $ip 2> /dev/null 1> /dev/null && continue
                fi

                last_ipv4=$(sipcalc $ip_and_netmask | grep 'Usable range' | cut -d ' ' -f5 | sed -e 's/255/254/g')
                i=0
                # while true; do
                while [ "$i" -le "10" ]; do
                    if [ "$_debug" ]; then
                        if ! fping -c1 -t200 $last_ipv4; then
                            if [ "$_arping" ]; then
                                arping -c1 -I $host_if $last_ipv4 || break
                            else
                                break
                            fi
                        fi
                    else
                        if ! fping -c1 -t200 $last_ipv4 2> /dev/null 1> /dev/null; then
                            if [ "$_arping" ]; then
                                arping -c1 -I $host_if $last_ipv4 2> /dev/null 1> /dev/null || break
                            else
                                break
                            fi
                        fi
                    fi
                    last_ipv4=$(_decrement_ipv4 $last_ipv4)
                    i=$(expr $i + 1)
                done
                last_ip="$last_ipv4"
                ;;

            inet6)
                unset last_ip
                if [ "$_debug" ]; then
                    fping6 -c1 -t200 $ip && continue
                    ndisc6 -1 -r1 -w200 $ip $host_if && continue
                else
                    fping6 -c1 -t200 $ip 2> /dev/null 1> /dev/null && continue
                    ndisc6 -1 -r1 -w200 $ip $host_if 2> /dev/null 1> /dev/null && continue
                fi

                last_ipv6=$(sipcalc $ip_and_netmask | grep -A1 'Network range' | tail -1)
                last_ipv6=$(_decrement_ipv6 $last_ipv6)
                i=0
                # while true; do
                while [ "$i" -le "10" ]; do
                    if [ "$_debug" ]; then
                        if ! fping6 -c1 -t200 $last_ipv6; then
                            if ! ndisc6 -1 -r1 -w200 $last_ipv6 $host_if; then
                                break
                            fi
                        fi
                    else
                        if ! fping6 -c1 -t200 $last_ipv6 2> /dev/null 1> /dev/null; then
                            if ! ndisc6 -1 -r1 -w200 $last_ipv6 $host_if 2> /dev/null 1> /dev/null; then
                                break
                            fi
                        fi
                    fi
                    last_ipv6=$(_decrement_ipv6 $last_ipv6)
                    i=$(expr $i + 1)
                done
                last_ip="$last_ipv6"
                ;;
        esac

        if [ "$last_ip" ]; then
            #  generate a unique macvlan interface name for the host route
            # e.g. 'pipework eth1 -i eth2 00aa00bb00cc dhcp' --> macvlan_ifname=12p00aa00bb00cc
            if_nums="$(echo $host_if | tr -d '[:alpha:]')$(echo $cont_if | tr -d '[:alpha:]')"
            macvlan_ifname="${if_nums}p${c12id}"

            # create a new host macvlan interface
            ip link add $macvlan_ifname link $host_if type macvlan mode bridge
            # give it the last available ip address in the container ip's subnet
            ip -f $proto addr add $last_ip/$netmask dev $macvlan_ifname
            # bring up the interface
            ip link set $macvlan_ifname up

            [ "$_pipework_route_add_delay" ] && sleep $_pipework_route_add_delay

            if [ "$_debug" ]; then
                # add a new route to container's ip address
                ip -f $proto route add $ip dev $macvlan_ifname
            else
                # add a new route to container's ip address
                ip -f $proto route add $ip dev $macvlan_ifname 2> /dev/null 1> /dev/null
            fi
        fi
    done

    # Apache 2.0 License, Credit @ jpetazzino
    # https://github.com/jpetazzo/pipework/blob/master/pipework#L294
    [ -f /var/run/netns/$_pid ] && rm -f /var/run/netns/$_pid
}

_run_pipework ()
{
    # Run pipework
    if [ "$_debug" ]; then
        $_pipework ${pipework_cmd#pipework }
    else
        $_pipework ${pipework_cmd#pipework } 2> /dev/null 1> /dev/null
    fi

    if [ $? != 0 ]; then
        unset retry_delay
        [ "$_pipework_retry_delay" ] && retry_delay="$_pipework_retry_delay"
        [ "$pipework_retry_delay" ]  && retry_delay="$pipework_retry_delay"

        if [ "$retry_delay" -gt 0 ] > /dev/null 2>&1; then
            sleep $retry_delay;

            # Run pipework again, the 2nd time
            if [ "$_debug" ]; then
                $_pipework ${pipework_cmd#pipework }
            else
                $_pipework ${pipework_cmd#pipework } 2> /dev/null 1> /dev/null
            fi
        fi
    fi

    unset inter_delay
    [ "$_pipework_inter_delay" ] && inter_delay="$_pipework_inter_delay"
    [ "$pipework_inter_delay" ]  && inter_delay="$pipework_inter_delay"
    [ "$inter_delay" ] && sleep $inter_delay;
}

_process_container ()
{
    c12id="$(echo "$1" | cut -c1-12)" # container_id
    event="$2" # start|stop
    unset $(env | grep -e ".*pipework.*" | cut -d= -f1)

    # Next 3 lines parses the docker inspect of the container and grabs the pertinent information out (env vars that pipework uses)
    _pipework_vars="$(docker inspect --format '{{range $index, $val := .Config.Env }}{{printf "%s\"\n" $val}}{{end}}' $c12id \
        | grep -e 'pipework_cmd.*=\|^pipework_key=\|pipework_host_route.*='| sed -e 's/^/export "/g')"
    [ "$_pipework_vars" ] || return 0

    echo "$_pipework_vars"

    # Picks the macros formed by @*****@ out of the _pipework_vars and stores them in _macros, then calls on _expand_macros to parse them to information
    # Planned macro support: @NODE_NUM@,
    _macros="$(echo -e "$_pipework_vars" | grep -o -e '@CONTAINER_NAME@\|@CONTAINER_ID@\|@HOSTNAME@\|@INSTANCE@\|@COMPOSE_PROJECT_NAME@\|@NODE_NUM@' | sort | uniq)"
    [ "$_macros" ] && _expand_macros;

    eval $_pipework_vars
    [ "$_pipework_key" ] && [ "$_pipework_key" != "$pipework_key" ] && return 0

    _pipework_cmds="$(env | grep -o -e '[^=]*pipework_cmd[^=]*' | sort)"
    [ "$_pipework_cmds" ]  || return 0


    # If the container is dying, initiate some proper cleanup and exit
    if [ "$event" = "die" ]; then
        cleanup_wait="$_default_cleanup_wait"
        [ "$_pipework_cleanup_wait" ] && cleanup_wait="$_pipework_cleanup_wait"
        [ "$pipework_cleanup_wait" ] && cleanup_wait="$pipework_cleanup_wait"
        sleep $cleanup_wait
        return 0
    fi

    # If the event is not death, then the container has started and as such we need to run pipework
    for pipework_cmd_varname in $_pipework_cmds; do
        pipework_cmd="$(eval echo "\$$pipework_cmd_varname")"

        # Run pipework
        _run_pipework;

	# These next lines never get used in our use cases, however are left in as they should still work
        pipework_host_route_varname="$(echo "$pipework_cmd_varname" | sed -e 's/pipework_cmd/pipework_host_route/g')"
        pipework_host_route="$(eval echo "\$$pipework_host_route_varname")"

        if [ "$_pipework_host_routes" ] || [ "$pipework_host_routes" ] || [ "$pipework_host_route" ]; then
            _create_host_route "$c12id" "${pipework_cmd#pipework }";
        fi


    done
}

_batch ()
{
    # process all currently running containers
    _batch_start_time="$(date +%s)"
    container_ids="$( docker ps | grep -v -e "CONTAINER\|${_pipework_image_name}" | cut -d ' ' -f1)"

    for container_id in $container_ids; do
        _process_container $container_id;
    done
}

_daemon ()
{
    [ "$_batch_start_time" ] && _pe_opts="$_pe_opts --since=$_batch_start_time"
    [ "$_pipework_up_time" ] && _pe_opts="$_pe_opts --until='$(expr $(date +%s) + $_pipework_up_time)'"

    if [ "$_pipework_event_filters" ]; then
        IFS=,
        for filter in $_pipework_event_filters; do
            _pe_opts="$_pe_opts --format=\'$filter\'"
        done
        unset IFS
    fi

    # Create docker events log
    _docker_events_log="/tmp/docker-events.log"
    rm -f $_docker_events_log
    touch $_docker_events_log
    chmod 0600 $_docker_events_log

    # http://stackoverflow.com/questions/1652680/how-to-get-the-pid-of-a-process-that-is-piped-to-another-process-in-bash
    # Create a background loop that constantly runs, waiting on the tail of /tmp/docker-events.log Only stops when the script cleanup trap hits
    tail_f_pid_file="$(mktemp -u --suffix=.pid /var/run/tail_f.XXX)"
    ( tail -f $_docker_events_log & echo $! >&3 ) 3>$tail_f_pid_file | \
    while true
    do
        read event_line
        echo event_line=$event_line

        # using $ docker events
	# event_line= 2016-08-09T14:33:09.210895432Z container die 49f8f33ae0ae9b17328c2dcd3ac4564952201ddc7202af0f86523bfd6f71f471 (exitCode=0, image=debian:8.5, name=pwt)

	# Ignore any containers that are from the image that this container is from
        event_line_sanitized="$(echo -e "$event_line" | grep -v "image=$_pipework_image_name" | tr -s ' ')"

	# Pull the container ID from the event line
        container_id="$(echo -e "$event_line_sanitized" | cut -d ' ' -f4)"

	# Pull the event (start|stop)
        event="$(echo -e "$event_line_sanitized" | cut -d ' ' -f3)"

	# Next 3 lines are for debugging purposes
        # echo event_line_sanitized=$event_line_sanitized
        # echo container_id=$container_id
        # echo event=$event

	#Check if we successfully pulled something to container ID and pass the ID and event to _process_container()
        [ "$container_id" ] && _process_container ${container_id%:} $event;

    done &

    # At the same time, we store the pid of the running loop and handle piping events to the /tmp/docker-events.log file
    _while_read_pid=$!
    _tail_f_pid=$(cat $tail_f_pid_file) && rm -f $tail_f_pid_file

    # Start to listen for new container start events and write them to the events log.
    # This sees only events that are start or stop, as well as gives you the ability to set custom filters
    docker events $_pe_opts --filter='event=start' --filter='event=die' \
        $_pipework_daemon_event_opts > $_docker_events_log &
    _docker_events_pid=$!

    # Wait until 'docker events' command is killed by 'trap _cleanup ...'
    wait $_docker_events_pid
    _cleanup;
}

_manual ()
{
    _pipework_cmds="$(env | grep -o -e '[^=]*pipework_cmd[^=]*')"
    if [ "$_pipework_cmds" ]; then
        for pipework_cmd_varname in $_pipework_cmds; do
            pipework_cmd="$(eval echo "\$$pipework_cmd_varname")"

            # Run pipework
            _run_pipework;

            pipework_host_route_varname="$(echo "$pipework_cmd_varname" | sed -e 's/pipework_cmd/pipework_host_route/g')"
            pipework_host_route="$(eval echo "\$$pipework_host_route_varname")"

            if [ "$_pipework_host_routes" ] || [ "$pipework_host_route" ]; then

                set ${pipework_cmd#pipework }
                [ "$2" = "-i" ] && container="$4" || container="$3"
                c12id="$($docker inspect --format '{{.Id}}' "$container" | cut -c1-12)"

                _create_host_route "$c12id" "${pipework_cmd#pipework }";
            fi
        done

    else
        # Run pipework
        _run_pipework;

        if [ "$_pipework_host_routes" ] || [ "$pipework_host_route" ]; then

            set ${_args#pipework }
            [ "$2" = "-i" ] && container="$4" || container="$3"
            c12id="$($docker inspect --format '{{.Id}}' "$container" | cut -c1-12)"

            _create_host_route "$c12id" "${_args#pipework }";
        fi
    fi
}

_main ()
{
    [ "$_pipework_debug" ] && set -x

    if echo "$_pipework_run_mode" | grep ',' 2> /dev/null 1> /dev/null; then
        # Ensure run_modes are processed in correct order: manual --> batch --> daemon
        _run_modes="$(echo manual batch daemon | \
            grep -o "$(echo "$_pipework_run_mode" | \
                sed -e 's/both/batch,daemon/g' -e 's/all/manual,batch,daemon/g' -e 's/,/\\|/g')")"

        for run_mode in $_run_modes; do
            eval "_${run_mode};"
        done

    elif [ "$_pipework_run_mode" ]; then
        case "$_pipework_run_mode" in
            manual)     _manual ;;
            batch)      _batch ;;
            daemon)     _daemon ;;
            both)       _batch; _daemon ;;
            all)        _manual; _batch; _daemon ;;
        esac
    else
        _manual;
    fi
}

# Begin
_test_docker;
_main;
