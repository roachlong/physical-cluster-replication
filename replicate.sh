#! /bin/bash

my_dir="$(dirname "$0")"

function_to_call="$1"
# echo "executing ${function_to_call} of the ${0} script under ${my_dir}"

put() {
    [ "$#" -lt 2 ] && exit 1
    local cluster_name=$1; local key=$2; local value=$3
    [ -d "settings/${cluster_name}" ] || mkdir -p "settings/${cluster_name}"
    echo ${value} > "settings/${cluster_name}/${key}"
}

get() {
    [ "$#" != 2 ] && exit 1
    local cluster_name=$1; local key=$2
    cat "settings/${cluster_name}/${key}"
}

config_primary() {
    echo "Time to CONFIGURE replication on the PRIMARY cluster"

    put primary database "defaultdb"
    read -p "What's the name of the database you want to connect with? <default $(get primary database)>: " database

    if [ -n "${database}" ] && [ ${database} != $(get primary database) ]; then
        put primary database "${database}"
    fi


    put primary rpl_usr "roachprod"
    read -p "What's the username of the primary user for setting up replication? <default $(get primary rpl_usr)>: " primary_user

    if [ -n "${primary_user}" ] && [ ${primary_user} != $(get primary rpl_usr) ]; then
        put primary rpl_usr "${primary_user}"
    fi


    put primary node "localhost"
    read -p "What's the hostname of the primary node for your primary databse cluster? <default $(get primary node)>: " primary_node

    if [ -n "${primary_node}" ] && [ ${primary_node} != $(get primary node) ]; then
        put primary node "${primary_node}"
    fi


    put primary url "postgresql://$(get primary rpl_usr):CHANGEME@$(get primary node):26257/$(get primary database)?sslcert=certs%2Fprimary%2Fclient.$(get primary rpl_usr).crt&sslkey=certs%2Fprimary%2Fclient.$(get primary rpl_usr).key&sslmode=verify-full&sslrootcert=certs%2Fprimary%2Fca.crt"
    echo "And what's the connection string url used to connect to this database?"
    echo "<default $(get primary url)>"
    read -p ": " primary_url

    if [ -n "${primary_url}" ] && [ ${primary_url} != $(get primary url) ]; then
        put primary url "${primary_url}"
    fi


    put primary ssh_usr "ubuntu"
    read -p "What's the username of the ssh user for connecting to $(get primary node)? <default $(get primary ssh_usr)>: " ssh_user

    if [ -n "${ssh_user}" ] && [ ${ssh_user} != $(get primary ssh_usr) ]; then
        put primary ssh_usr "${ssh_user}"
    fi

    cockroach sql --url "$(get primary url)" \
        -e "GRANT SYSTEM REPLICATION TO $(get primary rpl_usr);"

    cockroach sql --url "$(get primary url)" \
        -e "SET CLUSTER SETTING kv.rangefeed.enabled = true;"
}

config_secondary() {
    echo "Time to CONFIGURE replication on the SECONDARY cluster"

    put secondary database "defaultdb"
    read -p "What's the name of the database you want to connect with? <default $(get primary database)>: " database

    if [ -n "${database}" ] && [ ${database} != $(get secondary database) ]; then
        put secondary database "${database}"
    fi


    put secondary rpl_usr "roachprod"
    read -p "What's the username of the secondary user for setting up replication? <default $(get secondary rpl_usr)>: " secondary_user

    if [ -n "${secondary_user}" ] && [ ${secondary_user} != $(get secondary rpl_usr) ]; then
        put secondary rpl_usr "${secondary_user}"
    fi


    put secondary node "localhost"
    read -p "What's the hostname of the primary node for your secondary databse cluster? <default $(get secondary node)>: " secondary_node

    if [ -n "${secondary_node}" ] && [ ${secondary_node} != $(get secondary node) ]; then
        put secondary node "${secondary_node}"
    fi


    put secondary url "postgresql://$(get secondary rpl_usr):CHANGEME@$(get secondary node):26257/$(get secondary database)?sslcert=certs%2Fsecondary%2Fclient.$(get secondary rpl_usr).crt&sslkey=certs%2Fsecondary%2Fclient.$(get secondary rpl_usr).key&sslmode=verify-full&sslrootcert=certs%2Fsecondary%2Fca.crt"
    echo "And what's the connection string url used to connect to this database?"
    echo "<default $(get secondary url)>"
    read -p ": " secondary_url

    if [ -n "${secondary_url}" ] && [ ${secondary_url} != $(get secondary url) ]; then
        put secondary url "${secondary_url}"
    fi


    put secondary ssh_usr "ubuntu"
    read -p "What's the username of the ssh user for connecting to $(get secondary node)? <default $(get secondary ssh_usr)>: " ssh_user

    if [ -n "${ssh_user}" ] && [ ${ssh_user} != $(get secondary ssh_usr) ]; then
        put secondary ssh_usr "${ssh_user}"
    fi

    cockroach sql --url "$(get secondary url)" \
        -e "GRANT SYSTEM REPLICATION TO $(get secondary rpl_usr);"

    cockroach sql --url "$(get secondary url)" \
        -e "SET CLUSTER SETTING kv.rangefeed.enabled = true;"

    mkdir -p src-certs/primary
    scp $(get primary ssh_usr)@$(get primary node):certs/ca.crt src-certs/primary/ca.crt
    ssh -t $(get secondary ssh_usr)@$(get secondary node) 'mkdir -p src-certs/'
    scp src-certs/primary/ca.crt $(get secondary ssh_usr)@$(get secondary node):src-certs/ca.crt

    ssh -t $(get secondary ssh_usr)@$(get secondary node) """
        for ip in \$(./cockroach node status --certs-dir=certs --host=localhost --format=tsv | tail -n +2 | awk -F'\t' '{split(\$2, a, \":\"); print a[1]}'); do
            ssh -t $(get secondary ssh_usr)@\$ip 'mkdir -p src-certs/'
            scp src-certs/ca.crt $(get secondary ssh_usr)@\$ip:~/src-certs/.
        done
    """
}

exec_workload() {
    echo "Time to EXECUTE the workload on the PRIMARY cluster"

    db=$(get primary database)
    url=$(get primary url)
    if [ -z $(get primary workload) ]; then
        echo "initializing the workload on primary..."

        cockroach workload init kv \
            --min-block-bytes=4096 \
            --max-block-bytes=4096 \
            --insert-count=1310720 \
            --db=kvfill \
            ${url/${db}/kvfill}

        cockroach workload init tpcc ${url/${db}/tpcc}
        
        put primary workload tpcc
    fi

    read -p "For how many minutes would you like to run the workload? <Default 60>: " duration
    if [ -z "${duration}" ]; then
        duration=60
    fi

    cockroach workload run tpcc \
        --duration=${duration}m \
        ${url/${db}/tpcc}
}

start_pcr() {
    echo "Time to START PCR (physical cluster replication) to the SECONDARY cluster"

    url=$(get primary url)
    url="${url%%\?*}?sslmode=verify-full&sslrootcert=src-certs%2Fca.crt&options=-ccluster%3Dsystem"

    physical_sql="""
        CREATE VIRTUAL CLUSTER main
        FROM REPLICATION OF system
        ON '${url}';
    """

    cockroach sql --url "$(get secondary url)" \
        -e "${physical_sql}"
    
    sleep 5
    url="$(get secondary url)&options=-ccluster=system"
    cockroach sql --url="${url}" \
        -e "SHOW VIRTUAL CLUSTERS;"
}

stop_pcr() {
    echo "Time to STOP PCR (physical cluster replication) to the SECONDARY cluster"

    url="$(get secondary url)&options=-ccluster=system"

    cockroach sql --url "${url}" \
        -e "ALTER VIRTUAL CLUSTER main PAUSE REPLICATION;"

    while true; do
        status=$(cockroach sql --url "${url}" \
            -e "SHOW VIRTUAL CLUSTER main WITH REPLICATION STATUS;" \
            --format=csv | awk -F',' 'NR==2 {print $9}' | tr -d ' ')
        echo "Current status: ${status}"
        if [ "${status}" == "replicationpaused" ]; then
            break
        fi
        sleep 5
    done

    cockroach sql --url "${url}" \
        -e "ALTER VIRTUAL CLUSTER main COMPLETE REPLICATION TO LATEST;"

    while true; do
        status=$(cockroach sql --url "${url}" \
            -e "SHOW VIRTUAL CLUSTER main WITH REPLICATION STATUS;" \
            --format=csv | awk -F',' 'NR==2 {print $9}' | tr -d ' ')
        echo "Current status: ${status}"
        if [ "${status}" == "ready" ]; then
            break
        fi
        sleep 5
    done

    cockroach sql --url "${url}" \
        -e "ALTER VIRTUAL CLUSTER main START SERVICE SHARED;"
    cockroach sql --url="${url}" \
        -e "SHOW VIRTUAL CLUSTERS;"
}

drop_pcr() {
    echo "Time to DROP PCR (physical cluster replication) on the SECONDARY cluster"

    url="$(get secondary url)&options=-ccluster=system"

    cockroach sql --url "${url}" \
        -e "ALTER VIRTUAL CLUSTER main STOP SERVICE;"

    sleep 5
    cockroach sql --url "${url}" \
        -e "DROP VIRTUAL CLUSTER IF EXISTS main;"
}

test() {
    echo "Time to TEST something..."

    url="$(get secondary url)&options=-ccluster=system"
    cockroach sql --url="${url}" \
        -e "SHOW VIRTUAL CLUSTER 'main' WITH REPLICATION STATUS;"
}

case "$function_to_call" in
  "config_primary")
    config_primary
    ;;
  "config_secondary")
    config_secondary
    ;;
  "exec_workload")
    exec_workload
    ;;
  "start_pcr")
    start_pcr
    ;;
  "stop_pcr")
    stop_pcr
    ;;
  "drop_pcr")
    drop_pcr
    ;;
  "test")
    test
    ;;
  *)
    echo "Invalid function name: $function_to_call"
    ;;
esac
