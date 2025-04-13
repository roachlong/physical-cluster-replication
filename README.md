# phusical-cluster-replication
This is a quick setup to demonstrate replication in CRDB from a primary to a secondary cluster.  **Note** that PCR was introduced in v23.2.

It is assumed that you have a primary and secondary cluster with enterprise licenses running and that you have ssh access to both.  Cockroach SQL commands are executed locally against your cluster, but there are also steps to copy source (primary cluster) certs to the target (secondary cluster) that will execute commands remotely on one of the nodes in your cluster with ```ssh -t user@node ...```.

## 1 Configure Clusters For Replication
Execute the following commands to enable replication on your clusters.  This is a one time setup to store to confirm the configruation settings on the database.  You'll need the following information for each cluster:
1) **Database Name**: the name of the database in your connection string
2) **Database User**: the username that will be used to connect to the database and to configure replication, fyi dont' use root
3) **Primary Node**: the hostname or IP address for the primary node on your cluster
4) **Connection String**: the database url used to connect to the cluster
5) **System Account**: the username that will be used to ssh into the server without a password, it is assumed you have a public ssh keys installed and enabled
```
./replicate.sh config_primary
./replicate.sh config_secondary
```

## 2 Execute TPCC Workload
Next we can execute a sample workload on your primary database.  I would run this in a separate terminal.  It can be started before, duirng or after replication starts and you can run the workload multiple times.
```
./replicate.sh exec_workload
```

## 3 Test Physical Cluster Replication
1) Now we can start PCR to enable replication from the primary (source) cluster to the secondary (target) cluster.  During replication we can run the workload, but these scripts do not enable a read-only virtual cluster on the target.  So we won't be able to see the data until we cut over.
2) We can stop PCR when we're ready to treat the target cluster as a live environment.  Then you'll be able to connect and verify consistency between the databases.  However, note that failover we be a point in time, any changes to the source system will not be reflected in the target after the failover timestamp.  Also note that you will need to add "&options=-ccluster=main" to the end of your connection to connect to the virtual cluster with the replicated data.
3) Then we can drop PCR when we want to start over with a fresh replication from the source system.  You can repeat the cycle as many times as needed.
```
# 1) execute this step to initilate replication from the source to the target cluster
./replicate.sh start_pcr

# 2) this step will STOP replication and enable the target cluster to receive connections
./replicate.sh stop_pcr

# 3) execute this step if you want to remove replicated data from the target cluster
./replicate.sh drop_pcr
```

## Notes
The following steps are for internal scripts to stand-up and tear-down clusters using roachprod inside Cockroach Labs.

Stand-up:
```
(cd ../cockroachdb-starter/simple-bulk-insert; ./01_init_nodes.sh primary)
(cd ../cockroachdb-starter/simple-bulk-insert; ./01_init_nodes.sh secondary)
mkdir -p certs && cp -r ../cockroachdb-starter/simple-bulk-insert/certs .
```

Execute replication steps...

Tear-down:
```
(cd ../cockroachdb-starter/simple-bulk-insert; ./04_shutdown.sh secondary)
(cd ../cockroachdb-starter/simple-bulk-insert; ./04_shutdown.sh primary)
rm -rf src-certs certs settings
```