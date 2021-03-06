{% set standby = 'cdh5.hadoop.standby-namenode' in grains['roles'] %}
{% set kms = 'cdh5.hadoop.kms' in grains['roles'] %}
{% set dfs_name_dir = salt['pillar.get']('cdh5:dfs:name_dir', '/mnt/hadoop/hdfs/nn') %}
{% set mapred_local_dir = salt['pillar.get']('cdh5:mapred:local_dir', '/mnt/hadoop/mapred/local') %}
{% set mapred_system_dir = salt['pillar.get']('cdh5:mapred:system_dir', '/hadoop/system/mapred') %}
{% set mapred_staging_dir = '/user/history' %}
{% set mapred_log_dir = '/var/log/hadoop-yarn' %}

##
# Starts the namenode service.
#
# Depends on: JDK7
##

##
# Make sure the namenode metadata directory exists
# and is owned by the hdfs user
##
cdh5_dfs_dirs:
  cmd:
    - run
    - name: 'mkdir -p {{ dfs_name_dir }} && chown -R hdfs:hdfs `dirname {{ dfs_name_dir }}`'
    - unless: 'test -d {{ dfs_name_dir }}'
    - require:
      - pkg: hadoop-hdfs-namenode
      - file: /etc/hadoop/conf
      {% if pillar.cdh5.security.enable %}
      - cmd: generate_hadoop_keytabs
      {% endif %}

# Initialize HDFS. This should only run once, immediately
# following an install of hadoop.
init_hdfs:
  cmd:
    - run
    - user: hdfs
    - group: hdfs
    - name: 'hdfs namenode -format -force'
    - unless: 'test -d {{ dfs_name_dir }}/current'
    - require:
      - cmd: cdh5_dfs_dirs
      {% if pillar.cdh5.encryption.enable %}
      - cmd: chown-keystore
      {% endif %}

{% if standby %}
init_zkfc:
  cmd:
    - run
    - name: hdfs zkfc -formatZK
    - user: hdfs
    - group: hdfs
    - unless: 'zookeeper-client stat /hadoop-ha/{{ grains.namespace }} 2>&1 | grep "cZxid"'
    - require:
      - cmd: cdh5_dfs_dirs

# Start up the ZKFC
hadoop-hdfs-zkfc-svc:
  service:
    - running
    - name: hadoop-hdfs-zkfc
    - enable: true
    - require:
      - pkg: hadoop-hdfs-zkfc
      - cmd: init_zkfc
    - require_in:
      - service: hadoop-yarn-resourcemanager-svc
      - service: hadoop-mapreduce-historyserver-svc
    - watch:
      - file: /etc/hadoop/conf
{% endif %}

hadoop-hdfs-namenode-svc:
  service:
    - running
    - name: hadoop-hdfs-namenode
    - enable: true
    - require:
      - pkg: hadoop-hdfs-namenode
      # Make sure HDFS is initialized before the namenode
      # is started
      - cmd: init_hdfs
    - watch:
      - file: /etc/hadoop/conf

# When security is enabled, we need to get a kerberos ticket
# for the hdfs principal so that any interaction with HDFS
# through the hadoop client may authorize successfully.
# NOTE this means that any 'hdfs dfs' commands will need
# to require this state to be sure we have a krb ticket
{% if pillar.cdh5.security.enable %}
hdfs_kinit:
  cmd:
    - run
    - name: 'kinit -kt /etc/hadoop/conf/hdfs.keytab hdfs/{{ grains.fqdn }}'
    - user: hdfs
    - group: hdfs
    - env:
      - KRB5_CONFIG: '{{ pillar.krb5.conf_file }}'
    - require:
      - service: hadoop-hdfs-namenode-svc
      - cmd: generate_hadoop_keytabs
    - require_in:
      - cmd: hdfs_tmp_dir
      - cmd: hdfs_mapreduce_log_dir
      - cmd: hdfs_mapreduce_var_dir

mapred_kinit:
  cmd:
    - run
    - name: 'kinit -kt /etc/hadoop/conf/mapred.keytab mapred/{{ grains.fqdn }}'
    - user: mapred
    - env:
      - KRB5_CONFIG: '{{ pillar.krb5.conf_file }}'
    - require:
      - service: hadoop-hdfs-namenode-svc
      - cmd: generate_hadoop_keytabs
{% endif %}

# HDFS tmp directory
hdfs_tmp_dir:
  cmd:
    - run
    - user: hdfs
    - group: hdfs
    - name: 'hdfs dfs -mkdir /tmp && hdfs dfs -chmod -R 1777 /tmp'
    - unless: 'hdfs dfs -test -d /tmp'
    - require:
      - service: hadoop-hdfs-namenode-svc

# HDFS MapReduce log directories
hdfs_mapreduce_log_dir:
  cmd:
    - run
    - user: hdfs
    - group: hdfs
    - name: 'hdfs dfs -mkdir -p {{ mapred_log_dir }} && hdfs dfs -chown yarn:hadoop {{ mapred_log_dir }}'
    - unless: 'hdfs dfs -test -d {{ mapred_log_dir }}'
    - require:
      - service: hadoop-hdfs-namenode-svc

# HDFS MapReduce var directories
hdfs_mapreduce_var_dir:
  cmd:
    - run
    - user: hdfs
    - group: hdfs
    - name: 'hdfs dfs -mkdir -p {{ mapred_staging_dir }} && hdfs dfs -chmod -R 1777 {{ mapred_staging_dir }} && hdfs dfs -chown mapred:hadoop {{ mapred_staging_dir }}'
    - unless: 'hdfs dfs -test -d {{ mapred_staging_dir }}'
    - require:
      - service: hadoop-hdfs-namenode-svc

{% if kms %}
create_mapred_key:
  cmd:
    - run
    - user: mapred
    - name: 'hadoop key create mapred'
    - unless: 'hadoop key list | grep mapred'
    - require:
      - file: /etc/hadoop/conf
      {% if pillar.cdh5.security.enable %}
      - cmd: mapred_kinit
      {% endif %}

create_mapred_zone:
  cmd:
    - run
    - user: hdfs
    - name: 'hdfs crypto -createZone -keyName mapred -path {{ mapred_staging_dir }}'
    - unless: 'hdfs crypto -listZones | grep {{ mapred_staging_dir }}'
    - require:
      - cmd: create_mapred_key
      - cmd: hdfs_mapreduce_var_dir
    - require_in:
      - service: hadoop-yarn-resourcemanager-svc
      - service: hadoop-mapreduce-historyserver-svc
{% endif %}

# create a user directory for user
{% set user_obj = salt['pillar.get']('user') %}
{% set user = user_obj.username %}
hdfs_dir_{{ user }}:
  cmd:
    - run
    - user: hdfs
    - group: hdfs
    - name: 'hdfs dfs -mkdir -p /user/{{ user }} && hdfs dfs -chown {{ user }}:{{ user }} /user/{{ user }}'
    - require:
      - service: hadoop-hdfs-namenode-svc
      {% if pillar.cdh5.security.enable %}
      - cmd: hdfs_kinit
      {% endif %}

##
# Starts yarn resourcemanager service.
#
# Depends on: JDK7
##
hadoop-yarn-resourcemanager-svc:
  service:
    - running
    - name: hadoop-yarn-resourcemanager
    - enable: true
    - require:
      - pkg: hadoop-yarn-resourcemanager
      - service: hadoop-hdfs-namenode-svc
      - cmd: hdfs_mapreduce_var_dir
      - cmd: hdfs_mapreduce_log_dir
      - cmd: hdfs_tmp_dir
    - watch:
      - file: /etc/hadoop/conf

{% if standby %}
hadoop-yarn-proxyserver-svc:
  service:
    - running
    - name: hadoop-yarn-proxyserver
    - enable: true
    - require:
      - pkg: hadoop-yarn-proxyserver
      - service: hadoop-yarn-resourcemanager-svc
    - watch:
      - file: /etc/hadoop/conf
{% endif %}

##
# Installs the mapreduce historyserver service and starts it.
#
# Depends on: JDK7
##
hadoop-mapreduce-historyserver-svc:
  service:
    - running
    - name: hadoop-mapreduce-historyserver
    - enable: true
    - require:
      - pkg: hadoop-mapreduce-historyserver
      - service: hadoop-hdfs-namenode-svc
      - cmd: hdfs_mapreduce_var_dir
      - cmd: hdfs_mapreduce_log_dir
      - cmd: hdfs_tmp_dir
    - watch:
      - file: /etc/hadoop/conf
