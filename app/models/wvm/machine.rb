require 'httparty'
require 'recursive_open_struct'

class Wvm::Machine
  include HTTParty
  base_uri 'http://0.0.0.0:8000/'


  def self.all
    response = call :get, 'instances'

    machines = response.instances.map do |machine|
      Machine.new \
          hostname: machine[:name],
          memory: machine[:memory],
          space_available: machine.storage.map(&:capacity).inject(0, &:+)
    end

    memory = machines.map(&:memory).inject(0, &:+).megabytes
    storage = machines.map(&:space_available).inject(0, &:+)

    machines.sort_by! &:hostname

    {
      machines: machines,
      totals: {
        machines: machines.size,
        memory: memory,
        storage: storage
      }
    }
  end

  def self.find id
    response = call :get, "instances/#{id}"

    status = determine_status response

    storage_allocated = response.disks.map(&:allocation).inject(0, &:+)
    storage_capacity = response.disks.map(&:capacity).inject(0, &:+)
    space_usage = storage_allocated / storage_capacity

    Machine.new \
        hostname: response[:name],
        uuid: response[:uuid],
        memory: response[:cur_memory],
        processors: response[:vcpu],
        status: status,
        space_available: storage_capacity,
        space_usage: space_usage,
        vnc_password: response[:vnc_password]
  end

  OPERATIONS = {
      start: :start,
      pause: :suspend,
      resume: :resume,
      stop: :shutdown,
      force_stop: :destroy,
      restart: :restart
  }

  OPERATIONS.each do |operation_name, libvirt_name|
    define_singleton_method operation_name do |id|
      operation libvirt_name, id
    end
  end

  def self.force_restart id
    operation :destroy, id
    operation :start, id
  end

  private
  def self.operation operation, id
    errors = call(:post, 'instances', operation => '', name: id).errors
    if errors.size > 0
      raise Errors, errors
    end
  end

  def self.call method, url, **body
    params = {headers: {'Accept' => 'application/json'}}
    if method == :post
      params[:headers]['Content-Type'] = 'application/x-www-form-urlencoded'
      params[:body] = body
    end

    response = send method, "/1/#{url}.json", params

    RecursiveOpenStruct.new(response.to_hash, recurse_over_arrays: true)
  end

  def self.determine_status response
    status = case response[:status]
      when 1
        :running
      when 3
        :suspended
      when 5
        response[:has_managed_save_image] == 1 ? :saved : :stopped
      else
        :unknown
    end
    Machine::Status.find status
  end
end
