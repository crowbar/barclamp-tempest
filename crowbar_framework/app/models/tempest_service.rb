# Copyright 2011, Dell 
# Copyright 2012, Dell
# 
# Licensed under the Apache License, Version 2.0 (the "License"); 
# you may not use this file except in compliance with the License. 
# You may obtain a copy of the License at 
# 
#  http://www.apache.org/licenses/LICENSE-2.0 
# 
# Unless required by applicable law or agreed to in writing, software 
# distributed under the License is distributed on an "AS IS" BASIS, 
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. 
# See the License for the specific language governing permissions and 
# limitations under the License. 
# 


class TempestService < ServiceObject
  class ServiceError < StandardError
  end

  def proposal_dependencies(new_config)
    answer = []
    hash = new_config.config_hash
    answer << { "barclamp" => "nova", "inst" => hash["tempest"]["nova_instance"] }
    answer
  end

  def create_proposal(name)
    # TODO: ensure that only one proposal can be applied to a node
    @logger.debug("Tempest create_proposal: entering")
    base = super(name)
    @logger.debug("Tempest create_proposal: leaving base part")

    hash = base.config_hash

    nodes = Node.find_by_role_name("nova-multi-controller")
    nodes.delete_if { |n| n.nil? or n.admin? }
    unless nodes.empty?
      hash["tempest"]["elements"] = {
        "tempest" => [ nodes.first.name ]
      }
    end

    hash["tempest"]["nova_instance"] = ""
    begin
      novaService = Barclamp.find_by_name("nova")
      novas = novaService.active_proposals
      if novas.empty?
        # No actives, look for proposals
        novas = novaService.proposals
      end
      hash["tempest"]["nova_instance"] = novas[0].name unless novas.empty?
    rescue
      @logger.info("Tempest create_proposal: no nova found")
    end

    hash["tempest"]["tempest_user_username"] = "tempest-user-" + random_password
    hash["tempest"]["tempest_user_tenant"] = "tempest-tenant-" + random_password
    hash["tempest"]["tempest_user_password"] = random_password

    base.config_hash = hash
    @logger.debug("Tempest create_proposal: exiting")
    base
  end

  # GREG: HERE DOWN STILL NEEDS A PORT TO CB2.0
  def apply_role_pre_chef_call(old_role, role, all_nodes)
    @logger.debug("Tempest apply_role_pre_chef_call: entering #{all_nodes.inspect}")
    return if all_nodes.empty?

    # Update tempest_tarball path
    nodes = Node.find_by_role_name("provisioner-server")
    unless nodes.nil? or nodes.length < 1
      admin_ip = nodes[0].get_network_by_type("admin")["address"]
      web_port = nodes[0]["provisioner"]["web_port"]
      # substitute the admin web portal
      tempest_tarball_path = role.default_attributes["tempest"]["tempest_tarball"].gsub("<ADMINWEB>", "#{admin_ip}:#{web_port}")
      tempest_test_image_path = role.default_attributes["tempest"]["tempest_test_image"].gsub("<ADMINWEB>", "#{admin_ip}:#{web_port}")
      role.default_attributes["tempest"]["tempest_tarball"] = tempest_tarball_path
      role.default_attributes["tempest"]["tempest_test_image"] = tempest_test_image_path
    end

    role.save

    @logger.debug("Tempest apply_role_pre_chef_call: leaving")
  end

  def get_test_run_by_uuid(uuid)
    get_test_runs.each do |r|
        return r if r['uuid'] == uuid
    end
    nil
  end

  def self.get_all_nodes_hash
    Hash[ Node.all.map {|n| [n.name, n]} ]
  end

  def get_ready_nodes
    nodes = get_ready_proposals.collect { |p| p.elements[@bc_name] }.flatten
    Node.all.select { |n| nodes.include?(n.name) and n.ready? }
  end

  def get_ready_proposals
    ProposalObject.find_proposals(@bc_name).select {|p| p.status == 'ready'}.compact
  end

  def _get_or_create_db
    db = ProposalObject.find_data_bag_item "crowbar/#{@bc_name}"
    if db.nil?
      CrowbarUtils.with_lock(@bc_name) do
        db_item = Chef::DataBagItem.new
        db_item.data_bag "crowbar"
        db_item['id'] = @bc_name
        db_item['test_runs'] = []
        db = ProposalObject.new db_item
        db.save
      end
    end
    db
  end

  def get_test_runs
    _get_or_create_db['test_runs']
  end

  def clear_test_runs
    def delete_file(file_name)
      File.delete(file_name) if File.exist?(file_name)
    end

    def process_exists(pid)
      begin
        Process.getpgid( pid )
        true
      rescue Errno::ESRCH
        false
      end
    end

    tempest_db = _get_or_create_db

    @logger.info('cleaning out test runs and results')
    tempest_db['test_runs'].delete_if do |test_run|
      if test_run['status'] == 'running'
        if test_run['pid'] and not process_exists(test_run['pid'])
          @logger.warn("running tempest run #{test_run['uuid']} seems to be stale")
        elsif Time.now.utc.to_i - test_run['started'] > 60 * 60 * 4 # older than 4 hours
          @logger.warn("running tempest run #{test_run['uuid']} seems to be outdated, started at #{Time.at(test_run['started']).to_s}")
        else
          @logger.debug("omitting running test run #{test_run['uuid']} while cleaning")
          next
        end
      else
        delete_file(test_run['results.html'])
        delete_file(test_run['results.xml'])
      end
      @logger.debug("removing tempest run #{test_run['uuid']}")
      true
    end

    CrowbarUtils.with_lock(@bc_name) do tempest_db.save end
  end

  def run_test(node)
    raise "unable to look up a #{@bc_name} proposal at node #{node.inspect}" if (proposal = _get_proposal_by_node node).nil?
    
    test_run_uuid = `uuidgen`.strip
    test_run = { 
      'uuid' => test_run_uuid, 'started' => Time.now.utc.to_i, 'ended' => nil, 'pid' => nil,
      'status' => 'running', 'node' => node, 'results.xml' => "log/#{test_run_uuid}.xml", 
      'results.html' => "log/#{test_run_uuid}.html"}

    tempest_db = _get_or_create_db

    tempest_db['test_runs'].each do |tr|
      raise ServiceError, I18n.t("barclamp.#{@bc_name}.run.duplicate") if tr['node'] == node and tr['status'] == 'running'
    end

    CrowbarUtils.with_lock(@bc_name) do
      tempest_db['test_runs'] << test_run
      tempest_db.save
    end

    proposal_path = proposal['attributes'][@bc_name]['tempest_path']

    @logger.info("starting tempest on node #{node}, test run uuid #{test_run['uuid']}")
    pid = fork do
      command_line = "python #{proposal_path}/run_tempest.py -w #{proposal_path} tempest 2>/dev/null"
      Process.waitpid run_remote_chef_client(node, command_line, test_run['results.xml'])

      test_run['ended'] = Time.now.utc.to_i
      test_run['status'] = $?.exitstatus.equal?(0) ? 'passed' : 'failed'
      test_run['pid'] = nil
      CrowbarUtils.with_lock(@bc_name) do tempest_db.save end

      @logger.info("test run #{test_run['uuid']} complete, status '#{test_run['status']}'")
    end
    Process.detach pid

    # saving the PID to prevent 
    test_run['pid'] = pid
    CrowbarUtils.with_lock(@bc_name) do tempest_db.save end
    test_run
  end

  def _get_proposal_by_node(node)
    get_ready_proposals.each do |p|
      return p if p.elements[@bc_name].include? node
    end
    nil
  end
end
