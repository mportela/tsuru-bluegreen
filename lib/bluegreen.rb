require 'yaml'
require 'json'
require 'net/http'
require 'logger'
require 'debugger'

class BlueGreen
  def initialize(token, target, config)
    @token = token
    @target = target
    @app_name = config["name"]
    @hooks = config["hooks"] || {}
    @newrelic = config["newrelic"] || {}
    @webhook = config["webhook"] || {}

    @logger = Logger.new(STDOUT)
    @logger.level = Logger::INFO
  end

  def get_cname(app)
    res = request(:get, "#{@target}apps/#{app}")
    cnames = JSON.parse(res.body)["cname"]
    return cnames if cnames.length > 0
  end

  def remove_cname(app, cnames)
    return request(:delete, "#{@target}apps/#{app}/cname", payload: {"cname" => cnames}).code.to_i == 200
  end

  def set_cname(app, cnames)
    return request(:post, "#{@target}apps/#{app}/cname", payload: {"cname" => cnames}).code.to_i == 200
  end

  def env_set(app, key, value)
    return request(:post, "#{@target}apps/#{app}/env?noRestart=true", payload: {key => value}).code.to_i == 200
  end

  def env_get(app, key)
    res = request(:get, "#{@target}apps/#{app}/env", payload: [key])
    return if res.body === "null"

    values = JSON.parse(res.body)
    values[0]["value"] if values.length > 0
  end

  def total_units(app)
    units = JSON.parse(request(:get, "#{@target}apps/#{app}").body)["units"]

    process_count = {}
    units.each do |unit|
      process_name = unit["ProcessName"]
      process_count[process_name] ? process_count[process_name] += 1 : process_count[process_name] = 1
    end

    process_count
  end

  def remove_units(app, units_to_keep=0)
    total_units = total_units(app)
    results = total_units.map do |process_name, units|
      remove_units_per_process_type(app, units - units_to_keep, process_name)
    end

    results.all?
  end

  def add_units(app, total_units_after_add)
    total_units = total_units(app)

    results = total_units_after_add.map do |process_name, units|
      units_to_add = 0

      if total_units[process_name]
        units_to_add = units - total_units[process_name]
      else
        units_to_add = units
      end

     add_units_per_process_type(app, units_to_add, units, process_name) if units_to_add > 0
    end

    results.compact.all?
  end

  def notify_newrelic(tag)
    api_key = @newrelic['api_key']
    app_id = @newrelic['app_id']

    if api_key && app_id
      @logger.info("Notifying New Relic app '#{app_id}'")

      headers = {"Content-Type" =>  "application/x-www-form-urlencoded", "x-api-key" =>  api_key}
      res = request(:post, "http://api.newrelic.com/deployments.xml", payload: "deployment[application_id]=#{app_id}&deployment[revision]=#{tag}", headers: headers)
      return res.code.to_i == 200
    end

    return false
  end

  def run_webhook(tag)
    endpoint = @webhook['endpoint']
    payload_extras = @webhook['payload_extras']

    if endpoint && payload_extras
      @logger.info "POSTING to WebHook '#{endpoint}' ..."
      headers = {"Content-Type" =>  "application/x-www-form-urlencoded"}
      res = request(:post, endpoint, payload: "#{payload_extras}&tag=#{tag}", headers: headers)
      return res.code.to_i == 200
    end

    return false
  end

  def run_command(command, env_vars={})
    dev_null = '/dev/null'

    begin
      return system(env_vars, command, out: dev_null, err: dev_null)
    rescue
      return false
    end
  end

  def run_hook(hook_name, env_vars={})
    hook_command = @hooks[hook_name]

    if hook_command
      @logger.info "Running '#{hook_name}' hook ..."
      return run_command(hook_command, env_vars)
    end

    return true
  end

  private

  def add_units_per_process_type(app, units_to_add, total_units_after_add, process_name)
    res = request(:put, "#{@target}apps/#{app}/units?units=#{units_to_add}&process=#{process_name}")

    if (res.code.to_i != 200) || (total_units(app)[process_name] != total_units_after_add)
      puts "Error adding '#{units_to_add}' units to #{process_name} process in #{app}. Aborting..."
      return false
    end

    return true
  end

  def remove_units_per_process_type(app, units_to_remove, process_name)
    res = request(:delete, "#{@target}apps/#{app}/units?units=#{units_to_remove}&process=#{process_name}", headers: {"Content-Type" => "application/x-www-form-urlencoded"})

    if res.code.to_i != 200
      puts "Error removing '#{process_name}' units from #{app}. You'll need to remove manually."
      return false
    end

    return true
  end

  def default_headers
    {"Content-Type" => "application/json", "Authorization" => "bearer #{@token}"}
  end

  def request(method, url, params={})
    headers = params[:headers] || {}
    payload = params[:payload] || {}

    request_class = Net::HTTP.const_get(method.to_s.capitalize)

    uri = URI(url)
    req = request_class.new(uri.request_uri, default_headers.merge(headers))
    if payload.class == String
      req.body = payload
    else
      req.body = payload.to_json if payload.length > 0
    end

    Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(req) }
  end
end

