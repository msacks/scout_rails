# Logic for the serialized file access
class ScoutRails::LayawayFile
  def path
    "#{ScoutRails::Agent.instance.log_path}/scout_rails.db"
  end

  def dump(object)
    Marshal.dump(object)
  end

  def load(dump)
    if dump.size == 0
      ScoutRails::Agent.instance.logger.debug("No data in layaway file.")
      return nil
    end
    Marshal.load(dump)
  rescue ArgumentError, TypeError => e
    ScoutRails::Agent.instance.logger.debug("Error loading data from layaway file: #{e.inspect}")
    ScoutRails::Agent.instance.logger.debug(e.backtrace.inspect)
    nil
  end

  def read_and_write
    File.open(path, File::RDWR | File::CREAT) do |f|
      f.flock(File::LOCK_EX)
      begin
        result = (yield get_data(f))
        f.rewind
        f.truncate(0)
        if result
          write(f, dump(result))
        end
      ensure
        f.flock(File::LOCK_UN)
      end
    end
  rescue Errno::ENOENT, Exception  => e
    ScoutRails::Agent.instance.logger.error(e.message)
    ScoutRails::Agent.instance.logger.debug(e.backtrace.split("\n"))
  end

  def get_data(f)
    data = read_until_end(f)
    result = load(data)
    f.truncate(0)
    result
  end

  def write(f, string)
    result = 0
    while (result < string.length)
      result += f.write_nonblock(string)
    end
  rescue Errno::EAGAIN, Errno::EINTR
    IO.select(nil, [f])
    retry
  end

  def read_until_end(f)
    contents = ""
    while true
      contents << f.read_nonblock(10_000)
    end
  rescue Errno::EAGAIN, Errno::EINTR
    IO.select([f])
    retry
  rescue EOFError
    contents
  end
end