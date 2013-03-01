# Copyright 2011 Dell, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

unless node[:quantum][:use_gitrepo]
  package "quantum" do
    action :install
  end
else
  puts "git_refspec = #{node[:quantum][:git_refspec]}"
  pfs_and_install_deps(@cookbook_name)
  link_service @cookbook_name do
    bin_name "quantum-server --config-dir /etc/quantum/"
  end
  create_user_and_dirs(@cookbook_name)
  execute "quantum_cp_policy.json" do
    command "cp /opt/quantum/etc/policy.json /etc/quantum/"
    creates "/etc/quantum/policy.json"
  end
  execute "quantum_cp_rootwrap" do
    command "cp /opt/quantum/etc/rootwrap.conf /etc/quantum/ ; cp -r /opt/quantum/quantum/rootwrap /etc/quantum/rootwrap.d"
    creates "/etc/quantum/rootwrap.conf"
  end
#  pfs_and_install_deps "quantum" do
#    cookbook "quantum"
#    cnode quantum
#  end
end



service "quantum" do
  supports :status => true, :restart => true
  action :enable
end

::Chef::Recipe.send(:include, Opscode::OpenSSL::Password)

node.set_unless['quantum']['db']['password'] = secure_password
node.set_unless['quantum']['db']['ovs_password'] = secure_password

if node[:quantum][:sql_engine] == "mysql"
    Chef::Log.info("Configuring Quantum to use MySQL backend")

    include_recipe "mysql::client"

    package "python-mysqldb" do
        action :install
    end

    env_filter = " AND mysql_config_environment:mysql-config-#{node[:quantum][:mysql_instance]}"
    mysqls = search(:node, "roles:mysql-server#{env_filter}") || []
    if mysqls.length > 0
        mysql = mysqls[0]
        mysql = node if mysql.name == node.name
    else
        mysql = node
    end

    mysql_address = Chef::Recipe::Barclamp::Inventory.get_network_by_type(mysql, "admin").address if mysql_address.nil?
    Chef::Log.info("Mysql server found at #{mysql_address}")
    
    # Create the Quantum Database
    mysql_database "create #{node[:quantum][:db][:database]} database" do
        host    mysql_address
        username "db_maker"
        password mysql[:mysql][:db_maker_password]
        database node[:quantum][:db][:database]
        action :create_db
    end

    mysql_database "create dashboard database user" do
        host    mysql_address
        username "db_maker"
        password mysql[:mysql][:db_maker_password]
        database node[:quantum][:db][:database]
        action :query
        sql "GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, DROP, INDEX, ALTER on #{node[:quantum][:db][:database]}.* to '#{node[:quantum][:db][:user]}'@'%' IDENTIFIED BY '#{node[:quantum][:db][:password]}';"
    end

    # Create the Quantum Database
    mysql_database "create #{node[:quantum][:db][:database]} database" do
        host    mysql_address
        username "db_maker"
        password mysql[:mysql][:db_maker_password]
        database node[:quantum][:db][:ovs_database]
        action :create_db
    end

    mysql_database "create dashboard database user" do
        host    mysql_address
        username "db_maker"
        password mysql[:mysql][:db_maker_password]
        database node[:quantum][:db][:ovs_database]
        action :query
        sql "GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, DROP, INDEX, ALTER on #{node[:quantum][:db][:ovs_database]}.* to '#{node[:quantum][:db][:ovs_user]}'@'%' IDENTIFIED BY '#{node[:quantum][:db][:ovs_password]}';"
    end


    ovs_sql_connection = "mysql://#{node[:quantum][:db][:ovs_user]}:#{node[:quantum][:db][:ovs_password]}@#{mysql_address}/#{node[:quantum][:db][:ovs_database]}"
    sql_connection = "mysql://#{node[:quantum][:db][:user]}:#{node[:quantum][:db][:password]}@#{mysql_address}/#{node[:quantum][:db][:database]}"




elsif node[:quantum][:sql_engine] == "sqlite"
    Chef::Log.info("Configuring Quantum to use SQLite backend")
    sql_connection = "sqlite:////var/lib/quantum/quantum.db"
    file "/var/lib/quantum/quantum.db" do
        owner "quantum"
        action :create_if_missing
    end
end

rabbits = search(:node, "recipes:nova\\:\\:rabbit") || []
if rabbits.length > 0
  rabbit = rabbits[0]
  rabbit = node if rabbit.name == node.name
else
  rabbit = node
end
rabbit_address = Chef::Recipe::Barclamp::Inventory.get_network_by_type(rabbit, "admin").address
Chef::Log.info("Rabbit server found at #{rabbit_address}")
if rabbit[:nova]
  #agordeev:
  # rabbit settings will work only after nova proposal be deployed
  # and cinder services will be restarted then
  rabbit_settings = {
    :address => rabbit_address,
    :port => rabbit[:nova][:rabbit][:port],
    :user => rabbit[:nova][:rabbit][:user],
    :password => rabbit[:nova][:rabbit][:password],
    :vhost => rabbit[:nova][:rabbit][:vhost]
  }
else
  rabbit_settings = nil
end

template "/etc/quantum/quantum.conf" do
    source "quantum.conf.erb"
    mode "0644"
    owner "quantum"
    variables(
      :sql_connection => sql_connection,
      :sql_idle_timeout => node[:quantum][:sql][:idle_timeout],
      :sql_min_pool_size => node[:quantum][:sql][:min_pool_size],
      :sql_max_pool_size => node[:quantum][:sql][:max_pool_size],
      :sql_pool_timeout => node[:quantum][:sql][:pool_timeout],
      :debug => node[:quantum][:debug],
      :verbose => node[:quantum][:verbose],
      :admin_token => node[:quantum][:service][:token],
      :service_port => node[:quantum][:api][:service_port], # Compute port
      :service_host => node[:quantum][:api][:service_host],
      :use_syslog => node[:quantum][:use_syslog],
      :rabbit_settings => rabbit_settings

    )
    notifies :restart, resources(:service => "quantum"), :immediately
end

env_filter = " AND keystone_config_environment:keystone-config-#{node[:quantum][:keystone_instance]}"
keystones = search(:node, "recipes:keystone\\:\\:server#{env_filter}") || []
if keystones.length > 0
  keystone = keystones[0]
  keystone = node if keystone.name == node.name
else
  keystone = node
end


keystone_address = Chef::Recipe::Barclamp::Inventory.get_network_by_type(keystone, "admin").address if keystone_address.nil?
keystone_token = keystone["keystone"]["service"]["token"]
keystone_service_port = keystone["keystone"]["api"]["service_port"]
keystone_admin_port = keystone["keystone"]["api"]["admin_port"]
keystone_service_tenant = keystone["keystone"]["service"]["tenant"]
keystone_service_user = node["quantum"]["service_user"]
keystone_service_password = node["quantum"]["service_password"]
Chef::Log.info("Keystone server found at #{keystone_address}")
template "/etc/quantum/api-paste.ini" do
  source "api-paste.ini.erb"
  owner "quantum"
  group "root"
  mode "0640"
  variables(
    :keystone_ip_address => keystone_address,
    :keystone_admin_token => keystone_token,
    :keystone_service_port => keystone_service_port,
    :keystone_service_tenant => keystone_service_tenant,
    :keystone_service_user => keystone_service_user,
    :keystone_service_password => keystone_service_password,
    :keystone_admin_port => keystone_admin_port
  )
  notifies :restart, resources(:service => "quantum"), :immediately
end


directory "/etc/quantum/plugins/openvswitch/" do
   mode 00775
   owner "quantum"
   action :create
   recursive true
end

template "/etc/quantum/plugins/openvswitch/ovs_quantum_plugin.ini" do
  source "ovs_quantum_plugin.ini.erb"
  owner "quantum"
  group "root"
  mode "0640"
  variables(
      :ovs_sql_connection => ovs_sql_connection
  )
  notifies :restart, resources(:service => "quantum"), :immediately
end


#execute "quantum-manage db_sync" do
#  action :run
#end

my_ipaddress = Chef::Recipe::Barclamp::Inventory.get_network_by_type(node, "admin").address
pub_ipaddress = Chef::Recipe::Barclamp::Inventory.get_network_by_type(node, "public").address rescue my_ipaddress

node[:quantum][:monitor] = {} if node[:quantum][:monitor].nil?
node[:quantum][:monitor][:svcs] = [] if node[:quantum][:monitor][:svcs].nil?
node[:quantum][:monitor][:svcs] <<["quantum"]
node.save


keystone_register "quantum api wakeup keystone" do
  host keystone_address
  port keystone_admin_port
  token keystone_token
  action :wakeup
end

keystone_register "register quantum user" do
  host keystone_address
  port keystone_admin_port
  token keystone_token
  user_name keystone_service_user
  user_password keystone_service_password
  tenant_name keystone_service_tenant
  action :add_user
end

keystone_register "give quantum user access" do
  host keystone_address
  port keystone_admin_port
  token keystone_token
  user_name keystone_service_user
  tenant_name keystone_service_tenant
  role_name "admin"
  action :add_access
end

keystone_register "register quantum service" do
  host keystone_address
  port keystone_admin_port
  token keystone_token
  service_name "quantum"
  service_type "network"
  service_description "Openstack Quantum Service"
  action :add_service
end

keystone_register "register quantum endpoint" do
  host keystone_address
  port keystone_admin_port
  token keystone_token
  endpoint_service "quantum"
  endpoint_region "RegionOne"
  endpoint_publicURL "http://#{pub_ipaddress}:9696/"
  endpoint_adminURL "http://#{my_ipaddress}:9696/"
  endpoint_internalURL "http://#{my_ipaddress}:9696/"
#  endpoint_global true
#  endpoint_enabled true
  action :add_endpoint_template
end

def mask_to_bits(mask)
  octets = mask.split(".")
  count = 0
  octets.each do |octet|
    break if octet == "0"
    c = 1 if octet == "128"
    c = 2 if octet == "192"
    c = 3 if octet == "224"
    c = 4 if octet == "240"
    c = 5 if octet == "248"
    c = 6 if octet == "252"
    c = 7 if octet == "254"
    c = 8 if octet == "255"
    count = count + c
  end

  count
end

fixed_net=node[:network][:networks]["nova_fixed"]
fixed_range="#{fixed_net["subnet"]}/#{mask_to_bits(fixed_net["netmask"])}"
floating_net=node[:network][:networks]["nova_floating"]
floating_range="#{floating_net["subnet"]}/#{mask_to_bits(floating_net["netmask"])}"
execute "create_fixed_network" do
  command "quantum net-create fixed --shared --provider:network_type flat --provider:physical_network physnet1"
  not_if "quantum net-list | grep -q ' fixed '"
end
execute "create_floating_network" do
  command "quantum net-create floating --shared --router:external=True --provider:network_type flat --provider:physical_network physnet2"
  not_if "quantum net-list | grep -q ' floating '"
end

execute "create_fixed_subnet" do
  command "quantum subnet-create --name fixed fixed #{fixed_range}"
  not_if "quantum subnet-list | grep -q '#{fixed_range}'"
end
execute "create_floating_subnet" do
  command "quantum subnet-create --name floating floating #{floating_range}"
  not_if "quantum subnet-list | grep -q '#{floating_range}'"
end

execute "create_router" do
  command "quantum router-create router-floating ; quantum router-gateway-set router-floating floating ; quantum router-interface-add router-floating fixed"
  not_if "quantum router-list | grep -q router-floating"
end
