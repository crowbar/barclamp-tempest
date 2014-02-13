#
# Cookbook Name:: tempest
# Recipe:: config
#
# Copyright 2011, Dell, Inc.
# Copyright 2012, Dell, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

env_filter = " AND nova_config_environment:nova-config-#{node[:tempest][:nova_instance]}"

novas = search(:node, "roles:nova-multi-controller#{env_filter}") || []
if novas.length > 0
  nova = novas[0]
  nova = node if nova.name == node.name
else
  nova = node
end

env_filter = " AND keystone_config_environment:keystone-config-#{nova[:nova][:keystone_instance]}"

keystones = search(:node, "roles:keystone-server#{env_filter}") || []
if keystones.length > 0
  keystone = keystones[0]
  keystone = node if keystone.name == node.name
else
  keystone = node
end

keystone_port = keystone[:keystone][:api][:service_port]

comp_admin_user = keystone[:keystone][:admin][:username]
comp_admin_pass = keystone[:keystone][:admin][:password]
comp_admin_tenant = keystone[:keystone][:admin][:tenant]

alt_comp_user = keystone[:keystone][:default][:username]
alt_comp_pass = keystone[:keystone][:default][:password]
alt_comp_tenant = keystone[:keystone][:default][:tenant]

img_user = comp_admin_user
img_pass = comp_admin_pass
img_tenant = comp_admin_tenant

tempest_node = node
private_network_name = node[:tempest][:private_network_name]
tempest_comp_user = node[:tempest][:tempest_user_username]
tempest_comp_pass = node[:tempest][:tempest_user_password]
tempest_comp_tenant = node[:tempest][:tempest_user_tenant]

tempest_adm_user = node[:tempest][:tempest_adm_username]
tempest_adm_pass = node[:tempest][:tempest_adm_password]

keystone_address = Chef::Recipe::Barclamp::Inventory.get_network_by_type(keystone, "admin").address if keystone_address.nil?
keystone_token = keystone[:keystone][:service][:token]
keystone_admin_port = keystone[:keystone][:api][:admin_port]

env_filter = " AND glance_config_environment:glance-config-#{nova[:nova][:glance_instance]}"

glances = search(:node, "roles:glance-server#{env_filter}") || []
if glances.length > 0
  glance = glances[0]
  glance = node if glance.name == node.name
else
  glance = node
end

glance_address = Chef::Recipe::Barclamp::Inventory.get_network_by_type(glance, "admin").address if glance_address.nil?
glance_port = glance[:glance][:api][:bind_port]

flavor_ref = "6"
alt_flavor_ref = "7"

keystone_register "tempest tempest wakeup keystone" do
  host keystone_address
  port keystone_admin_port
  token keystone_token
  action :wakeup
end.run_action(:wakeup)

keystone_register "create tenant #{tempest_comp_tenant} for tempest" do
  host keystone_address
  port keystone_admin_port
  token keystone_token
  tenant_name tempest_comp_tenant
  action :add_tenant
end.run_action(:add_tenant)

users = [
          {'name' => tempest_comp_user, 'pass' => tempest_comp_pass, 'role' => 'Member'},
          {'name' => tempest_adm_user, 'pass' => tempest_adm_pass, 'role' => 'admin' },
        ]
users.each do |user|

  keystone_register "add #{user["name"]}:#{user["pass"]} user" do
    host keystone_address
    port keystone_admin_port
    token keystone_token
    user_name user["name"]
    user_password user["pass"]
    tenant_name tempest_comp_tenant 
    action :add_user
  end.run_action(:add_user)

  keystone_register "add #{user["name"]}:#{tempest_comp_tenant} user #{user["role"]} role" do
    host keystone_address
    port keystone_admin_port
    token keystone_token
    user_name user["name"]
    role_name user["role"]
    tenant_name tempest_comp_tenant 
    action :add_access
  end.run_action(:add_access)

  keystone_register "add default tempest_ec2 creds for #{user["name"]}:#{user["role"]} in tenant #{tempest_comp_tenant}" do
     protocol node[:keystone][:api][:protocol]
     host keystone_address
     auth ({
         :tenant => comp_admin_tenant,
         :user => comp_admin_user,
         :password => comp_admin_pass
     })
     port keystone_admin_port
     user_name user["name"]
     tenant_name tempest_comp_tenant
     action :add_ec2
   end.run_action(:add_ec2)

end

directory "#{node[:tempest][:tempest_path]}/etc" do
  action :create
end

directory "#{node[:tempest][:tempest_path]}/etc/certs" do
  action :create
end

directory "#{node[:tempest][:tempest_path]}/etc/cirros" do
  action :create
end


machine_id_file = node[:tempest][:tempest_path] + '/machine.id'

venv_prefix_path = node[:tempest][:use_virtualenv] ? ". /opt/tempest/.venv/bin/activate && " : nil
ENV['PATH'] = ENV['PATH'] + ":/opt/tempest/.venv/bin" if node[:tempest][:use_virtualenv]

provisioner = search(:node, "roles:provisioner-server").first
extra_image_url = "http://#{provisioner[:fqdn]}:#{provisioner[:provisioner][:web_port]}/files/ami/cirros-0.3.0-x86_64-uec.tar.gz" || node[:tempest][:extra_image_url]

bash "upload tempest test image" do
  code <<-EOH
IMAGE_URL=${IMAGE_URL:-"#{extra_image_url}"}

OS_USER=${OS_USER:-admin}
OS_TENANT=${OS_TENANT:-admin}
OS_PASSWORD=${OS_PASSWORD:-admin}

TEMP=$(mktemp -d)
IMG_DIR=$TEMP/image
IMG_FILE=$(basename $IMAGE_URL)
IMG_NAME="${IMG_FILE%-*}"

function glance_it() {
#{venv_prefix_path} glance -I $OS_USER -T $OS_TENANT -K $OS_PASSWORD -N http://$KEYSTONE_HOST:5000/v2.0 -H $GLANCE_HOST $@
}

function extract_id() {
cut -d ":" -f2 | tr -d " "
}

function findfirst() {
find $IMG_DIR -name "$1" | head -1
}

echo "Downloading image ... "
wget $IMAGE_URL --directory-prefix=$TEMP || exit $?

echo "Unpacking image ... "
mkdir $IMG_DIR
tar -xvzf $TEMP/$IMG_FILE -C $IMG_DIR || exit $?
rm -rf #{node[:tempest][:tempest_path]}/etc/cirros/*
cp -v $(findfirst '*-vmlinuz') $(findfirst '*-initrd') $(findfirst '*.img') #{node[:tempest][:tempest_path]}/etc/cirros/

echo -n "Adding kernel ... "
KERNEL_ID=$(glance_it add --silent-upload name="$IMG_NAME-tempest-kernel" is_public=false container_format=aki disk_format=aki < $(findfirst '*-vmlinuz') | extract_id)
echo "done."

echo -n "Adding ramdisk ... "
RAMDISK_ID=$(glance_it add --silent-upload name="$IMG_NAME-tempest-ramdisk" is_public=false container_format=ari disk_format=ari < $(findfirst '*-initrd') | extract_id)
echo "done."

echo -n "Adding image ... "
MACHINE_ID=$(glance_it add --silent-upload name="$IMG_NAME-tempest-machine" is_public=false container_format=ami disk_format=ami kernel_id=$KERNEL_ID ramdisk_id=$RAMDISK_ID < $(findfirst '*.img') | extract_id)
echo "done."

echo -n "Saving machine id ..."
echo $MACHINE_ID > #{machine_id_file}
echo "done."

glance_it index
EOH
  environment ({
    'IMAGE_URL' => node[:tempest][:tempest_test_image],
    'OS_USER' => tempest_comp_user,
    'OS_PASSWORD' => tempest_comp_pass,
    'OS_TENANT' => tempest_comp_tenant,
    'KEYSTONE_HOST' => keystone_address,
    'GLANCE_HOST' => glance_address
  })
  not_if { File.exists?(machine_id_file) }
end

bash "create_yet_another_tiny_flavor" do
  code <<-EOH
  #{venv_prefix_path} nova --os_username #{tempest_adm_user} --os_password #{tempest_adm_pass} --os_tenant_name #{tempest_comp_tenant} --os_auth_url http://#{keystone_address}:5000/v2.0 flavor-create tempest-stuff #{alt_flavor_ref} 128 1 1 || exit 0
  #{venv_prefix_path} nova --os_username #{tempest_adm_user} --os_password #{tempest_adm_pass} --os_tenant_name #{tempest_comp_tenant} --os_auth_url http://#{keystone_address}:5000/v2.0 flavor-create tempest-stuff-2 #{flavor_ref} 132 1 1 || exit 0
EOH
end

# EC2 environment configuration start
node[:tempest][:ec2_access] = `keystone --os_username #{tempest_comp_user} --os_password #{tempest_comp_pass} --os_tenant_name #{tempest_comp_tenant} --os_auth_url http://#{keystone_address}:5000/v2.0 ec2-credentials-list | grep -v '\\-\\{5\\}' | tail -n 1 | tr -d '|' | awk '{print $2}'`
node[:tempest][:ec2_secret] = `keystone --os_username #{tempest_comp_user} --os_password #{tempest_comp_pass} --os_tenant_name #{tempest_comp_tenant} --os_auth_url http://#{keystone_address}:5000/v2.0 ec2-credentials-list | grep -v '\\-\\{5\\}' | tail -n 1 | tr -d '|' | awk '{print $3}'`
euca_key_dir = node[:tempest][:tempest_path] ? "#{node[:tempest][:tempest_path]}/etc/certs" : "/opt/tempest/etc/certs"
ec2_eucalyptus_cert = "#{euca_key_dir}/cacert.pem"
ec2_cert = "#{euca_key_dir}/cert.pem"
ec2_private_key = "#{euca_key_dir}/pk.pem"
ec2_url = "http://#{nova.name}:8773/services/Cloud"
s3_url = "http://#{nova.name}:3333/"
cirros_version = "0.3.0"
# EC2 environment configuration end

cli_dir = nova[:nova][:use_gitrepo] ? '/usr/local/bin' : '/usr/bin'
ext_net_id = `neutron --os_username #{tempest_adm_user} --os_password #{tempest_adm_pass} --os_tenant_name #{tempest_comp_tenant} --os_auth_url http://#{keystone_address}:5000/v2.0 net-list | grep floating | awk {'print $2'}`.strip
ext_rtr_id = `neutron --os_username #{tempest_adm_user} --os_password #{tempest_adm_pass} --os_tenant_name #{tempest_comp_tenant} --os_auth_url http://#{keystone_address}:5000/v2.0 router-list | grep floating | awk {'print $2'}`.strip




template "#{node[:tempest][:tempest_path]}/etc/tempest.conf" do
  source "tempest.conf.erb"
  mode 0644
  variables(
    :key_host => keystone_address,
    :key_port => keystone_port,
    :comp_user => tempest_comp_user,
    :comp_pass => tempest_comp_pass,
    :comp_tenant => tempest_comp_tenant,
    :alt_comp_user => alt_comp_user,
    :alt_comp_pass => alt_comp_pass,
    :alt_comp_tenant => alt_comp_tenant,
    :img_host => glance_address,
    :img_port => glance_port,
    :machine_id_file => machine_id_file,
    :flavor_ref => flavor_ref,
    :alt_flavor_ref => alt_flavor_ref,
    :img_user => tempest_comp_user,
    :img_pass => tempest_comp_pass,
    :img_tenant => tempest_comp_tenant,
    :comp_admin_user => comp_admin_user,
    :comp_admin_pass => comp_admin_pass,
    :comp_admin_tenant => comp_admin_tenant,
    :cli_dir => cli_dir,
    :tempest_path => node[:tempest][:tempest_path],
    :ec2_access => node[:tempest][:ec2_access],
    :ec2_secret => node[:tempest][:ec2_secret],
    :ec2_url => ec2_url,
    :s3_url => s3_url,
    :nova_host => nova.name,
    :cirros_version => cirros_version,
    :ext_net_id => ext_net_id,
    :ext_rtr_id => ext_rtr_id,
    :tempest_node => tempest_node,
    :private_network_name => private_network_name,
    :extra_image_url => extra_image_url
  )
end

template "/root/.eucarc" do
  source "eucarc.erb"
  mode 0600
  owner "root"
  group "root"
  variables(
    :ec2_eucalyptus_cert => ec2_eucalyptus_cert,
    :ec2_cert => ec2_cert,
    :ec2_private_key => ec2_private_key,
    :ec2_url => ec2_url,
    :s3_url => s3_url,
    :ec2_access => node[:tempest][:ec2_access],
    :ec2_secret => node[:tempest][:ec2_secret]
    )
end

nosetests = `PATH=#{ENV['PATH']} && which nosetests`.strip

if node[:tempest][:use_virtualenv]
  nosetests = "/opt/tempest/.venv/bin/python #{nosetests}"
end

template "/tmp/tempest_smoketest.sh" do
  mode 0755
  source "tempest_smoketest.sh.erb"
  variables(
    :nosetests => nosetests,
    :key_host => keystone_address,
    :key_port => keystone_port,
    :comp_user => tempest_comp_user,
    :comp_pass => tempest_comp_pass,
    :comp_tenant => tempest_comp_tenant,
    :alt_comp_user => alt_comp_user,
    :alt_comp_pass => alt_comp_pass,
    :alt_comp_tenant => alt_comp_tenant,
    :comp_admin_user => comp_admin_user,
    :comp_admin_pass => comp_admin_pass,
    :comp_admin_tenant => comp_admin_tenant,
    :tempest_path => node[:tempest][:tempest_path],
    :euca_key_dir => euca_key_dir,
    :ec2_eucalyptus_cert => ec2_eucalyptus_cert,
    :ec2_cert => ec2_cert,
    :ec2_private_key => ec2_private_key,
    :ec2_url => ec2_url,
    :s3_url => s3_url,
    :ec2_access => node[:tempest][:ec2_access],
    :ec2_secret => node[:tempest][:ec2_secret]
  )
end

cookbook_file "#{node[:tempest][:tempest_path]}/run_tempest.py" do
  source "run_tempest.py"
end
