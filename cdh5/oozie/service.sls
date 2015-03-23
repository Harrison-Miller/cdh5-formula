{% set oozie_data_dir = '/var/lib/oozie' %}
{% set nn_host = salt['mine.get']('G@stack_id:' ~ grains.stack_id ~ ' and G@roles:cdh5.hadoop.namenode and not G@roles:cdh5.hadoop.standby', 'grains.items', 'compound').values()[0]['fqdn_ip4'][0] %}
# 
# Start the Oozie service
#
{% if grains['os_family'] == 'Debian' %}
extend:
  remove_policy_file:
    file:
      - require:
        - service: oozie-svc
{% endif %}

oozie-svc:
  service:
    - running
    - name: oozie
    - require:
      - pkg: oozie
      - cmd: extjs
      - cmd: ooziedb
      - cmd: populate-oozie-sharelibs
      - file: /var/log/oozie
      - file: /var/lib/oozie
    - watch:
      - cmd: ooziedb
      - cmd: populate-oozie-sharelibs
{% if salt['pillar.get']('cdh5:security:enable', False) %}
      - file: /etc/oozie/conf/oozie-site.xml
      - cmd: generate_oozie_keytabs
{% endif %}


ooziedb:
  cmd:
    - run
    - name: '/usr/lib/oozie/bin/ooziedb.sh create -run'
    - unless: 'test -d {{ oozie_data_dir }}/oozie-db'
    - user: oozie
    - require:
      - pkg: oozie
      - cmd: extjs
{% if salt['pillar.get']('cdh5:security:enable', False) %}
      - file: /etc/oozie/conf/oozie-site.xml
      - cmd: generate_oozie_keytabs
{% endif %}

create-oozie-sharelibs:        
  cmd:
    - run
    - name: 'hdfs dfs -mkdir /user/oozie && hdfs dfs -chown -R oozie:oozie /user/oozie'
    - unless: 'hdfs dfs -test -d /user/oozie'
    - user: hdfs
    - require:
      - cmd: ooziedb

populate-oozie-sharelibs:
  cmd:
    - run
    - name: 'oozie-setup sharelib create -fs hdfs://{{nn_host}}:8020 -locallib /usr/lib/oozie/oozie-sharelib-yarn.tar.gz'
    - unless: 'hdfs dfs -test -d /user/oozie/share'
    - user: root
    - require:
      - cmd: create-oozie-sharelibs

{% if salt['pillar.get']('cdh5:security:enable', False) %}
# For some reason the oozie keytab is bad after we start oozie... so we'll regenerate the keytab
# now to fix it
regenerate_oozie_keytabs:
  cmd:
    - script
    - source: salt://cdh5/oozie/security/generate_keytabs.sh
    - template: jinja
    - user: root
    - group: root
    - cwd: /etc/oozie/conf
    - require:
      - module: load_admin_keytab
      - service: oozie-svc
{% endif %}
