require 'shellwords'

apt_update 'update'

# variables
root_pass_master = 'MyPa$$word\Has_"Special\'Chars%!'
root_pass_slave = 'An0th3r_Pa%%w0rd!'

# Debug message
Chef::Log.error "\n\n" + '=' * 80 + "\n\nTesting MySQL version '#{node['mysql']['version']}'\n\n" + '=' * 80

cmd = <<-EOH
#!/bin/bash
echo https://stackoverflow.com/a/37152673/1495086
if ps -p1|grep -q init; then
  echo "non-docker"
else
  echo "docker"
fi

echo https://stackoverflow.com/a/35751063/1495086
grep -qa container=lxc /proc/1/environ

echo https://stackoverflow.com/a/37016302/1495086
cat /proc/1/sched | head -n 1

echo https://stackoverflow.com/a/41559867/1495086
if grep docker /proc/1/cgroup -qa; then
   echo I am running in docker.
else
   echo I am not running in docker.
fi
EOH

log_bash = Mixlib::ShellOut.new(cmd)
log_bash.run_command
Chef::Log.error "\n\n" + '=' * 80 + "\n\ndocker status: #{log_bash.stdout}\n\n" + '=' * 80

log_lsb = <<EOL
ohai virutalization system: #{node['virtualization']['system']}, role: #{node['virtualization']['role']}
lsb id: #{node['lsb']['id']}
lsb description: #{node['lsb']['description']}
lsb release: #{node['lsb']['release']}
lsb release: #{node['lsb']['release']}
lsb codename: #{node['lsb']['codename']}
EOL
Chef::Log.error "\n\n" + '=' * 80 + "\n\n#{log_lsb}\n\n" + '=' * 80

# master
mysql_service 'master' do
  port '3306'
  version node['mysql']['version']
  initial_root_password root_pass_master
  action [:create, :start]
end

mysql_config 'master replication' do
  config_name 'replication'
  instance 'master'
  source 'replication-master.erb'
  variables(server_id: '1', mysql_instance: 'master')
  notifies :restart, 'mysql_service[master]', :immediately
  action :create
end

# MySQL client
mysql_client 'master' do
  action :create
end

# slave-1
mysql_service 'slave-1' do
  port '3307'
  version node['mysql']['version']
  initial_root_password root_pass_slave
  action [:create, :start]
end

mysql_config 'replication-slave-1' do
  instance 'slave-1'
  source 'replication-slave.erb'
  variables(server_id: '2', mysql_instance: 'slave-1')
  notifies :restart, 'mysql_service[slave-1]', :immediately
  action :create
end

# slave-2
mysql_service 'slave-2' do
  port '3308'
  version node['mysql']['version']
  initial_root_password root_pass_slave
  action [:create, :start]
end

mysql_config 'replication-slave-2' do
  instance 'slave-2'
  source 'replication-slave.erb'
  variables(server_id: '3', mysql_instance: 'slave-2')
  notifies :restart, 'mysql_service[slave-2]', :immediately
  action :create
end

# Create user repl on master
bash 'create replication user' do
  code <<-EOF
  /usr/bin/mysql -u root -h 127.0.0.1 -P 3306 -p#{Shellwords.escape(root_pass_master)} -D mysql -e "CREATE USER 'repl'@'127.0.0.1' IDENTIFIED BY 'REPLICAAATE';"
  /usr/bin/mysql -u root -h 127.0.0.1 -P 3306 -p#{Shellwords.escape(root_pass_master)} -D mysql -e "GRANT REPLICATION SLAVE ON *.* TO 'repl'@'127.0.0.1';"
  EOF
  not_if "/usr/bin/mysql -u root -h 127.0.0.1 -P 3306 -p#{Shellwords.escape(root_pass_master)} -e 'select User,Host from mysql.user' | grep repl"
  action :run
end

# take a dump
bash 'create /root/dump.sql' do
  user 'root'
  code <<-EOF
    mysqldump \
    --defaults-file=/etc/mysql-master/my.cnf \
    -u root \
    --protocol=tcp \
    -p#{Shellwords.escape(root_pass_master)} \
    --skip-lock-tables \
    --single-transaction \
    --flush-logs \
    --hex-blob \
    --master-data=2 \
    -A \ > /root/dump.sql;
   EOF
  not_if { ::File.exist?('/root/dump.sql') }
  action :run
end

# stash replication start position on the filesystem
bash 'stash position in /root/position' do
  user 'root'
  code <<-EOF
    head /root/dump.sql -n80 \
    | grep 'MASTER_LOG_POS' \
    | awk '{ print $6 }' \
    | cut -f2 -d '=' \
    | cut -f1 -d';' \
    > /root/position
  EOF
  not_if { ::File.exist?('/root/position') }
  action :run
end

# import dump into slaves
bash 'slave-1 import' do
  user 'root'
  code "/usr/bin/mysql -u root -h 127.0.0.1 -P 3307 -p#{Shellwords.escape(root_pass_slave)} < /root/dump.sql"
  not_if "/usr/bin/mysql -u root -h 127.0.0.1 -P 3307 -p#{Shellwords.escape(root_pass_slave)} -e 'select User,Host from mysql.user' | grep repl"
  action :run
end

bash 'slave-2 import' do
  user 'root'
  code "/usr/bin/mysql -u root -h 127.0.0.1 -P 3308 -p#{Shellwords.escape(root_pass_slave)} < /root/dump.sql"
  not_if "/usr/bin/mysql -u root -h 127.0.0.1 -P 3308 -p#{Shellwords.escape(root_pass_slave)} -e 'select User,Host from mysql.user' | grep repl"
  action :run
end

# start replication on slave-1
ruby_block 'start_slave_1' do
  block { start_slave_1(root_pass_slave) } # libraries/helpers.rb
  not_if "/usr/bin/mysql -u root -h 127.0.0.1 -P 3307 -p#{Shellwords.escape(root_pass_slave)} -e 'SHOW SLAVE STATUS\G' | grep Slave_IO_State"
  action :run
end

# start replication on slave-2
ruby_block 'start_slave_2' do
  block { start_slave_2(root_pass_slave) } # libraries/helpers.rb
  not_if "/usr/bin/mysql -u root -h 127.0.0.1 -P 3308 -p#{Shellwords.escape(root_pass_slave)} -e 'SHOW SLAVE STATUS\G' | grep Slave_IO_State"
  action :run
end

# create databass on master
bash 'create databass' do
  code <<-EOF
  echo 'CREATE DATABASE databass;' | /usr/bin/mysql -u root -h 127.0.0.1 -P 3306 -p#{Shellwords.escape(root_pass_master)};
  echo 'CREATE TABLE databass.table1 (name VARCHAR(20), rank VARCHAR(20));' | /usr/bin/mysql -u root -h 127.0.0.1 -P 3306 -p#{Shellwords.escape(root_pass_master)};
  echo "INSERT INTO databass.table1 (name,rank) VALUES('captain','awesome');" | /usr/bin/mysql -u root -h 127.0.0.1 -P 3306 -p#{Shellwords.escape(root_pass_master)};
  EOF
  not_if "/usr/bin/mysql -u root -h 127.0.0.1 -P 3306 -p#{Shellwords.escape(root_pass_master)} -e 'show databases' | grep databass"
  action :run
end
