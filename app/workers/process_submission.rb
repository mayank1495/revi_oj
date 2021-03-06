class ProcessSubmission

  include Process
  include Sidekiq::Worker
  sidekiq_options unique: true, :queue => :default, :retry => 5
  require 'scanf'

  #Docker::API_VERSION = '1.11.2'

  def perform(args)
    file_extensions = { 'c++' => '.cpp', 'java' => '.java', 'python' => '.py', 'c' => '.cc' }
    submission_id = args["submission_id"]
    submission = get_submission(submission_id)
    if submission.nil?
      return
    end
    langcode = submission.language[:langcode]
    user_email = submission.user[:email]
    problem = submission.problem
    pcode = problem[:pcode]
    ccode = problem.contest[:ccode]
    tlimit = problem[:time_limit] * submission.language[:time_multiplier]
    mlimit = problem[:memory_limit]

    @user_compile_path = "#{CONFIG[:base_path]}/#{user_email}/#{ccode}/#{pcode}/#{submission_id}/"

    if langcode == 'c++'
      compile_path = "bash -c 'g++ -std=c++0x -w -O2 -fomit-frame-pointer -lm -o ./compiled_code ./user_source_code#{file_extensions[langcode]} >& ./compiler'"
    elsif langcode == 'c'
      compile_path = "bash -c 'gcc -std=gnu99 -w -O2 -fomit-frame-pointer -lm -o ./compiled_code ./user_source_code#{file_extensions[langcode]} >& ./compiler'"
    elsif langcode == 'java'
      compile_path = "bash -c 'javac ./Main#{file_extensions[langcode]} >& ./compiler'"
    elsif langcode == 'python'
      compile_path = "bash -c 'python -m py_compile ./user_source_code#{file_extensions[langcode]} >& ./compiler'"
    end
    pid = spawn(compile_path, :chdir => @user_compile_path)
    pid, status = wait2(pid, 0)
    if !status.exited? || status.exitstatus.to_i != 0
      compilation_error = nil
      begin
        compilation_error = File.read(@user_compile_path + "compiler")
      rescue
        compilation_error = "Unknown error"
      end
      submission.update_attributes!(status_code: "CE", error_description: compilation_error)
      return
    end

    signal_list = Signal.list.invert
    signal_list_new = {}
    signal_list.each { |i,j| signal_list_new.merge!({ i + 128 => j }) }
    signal_list.merge!(signal_list_new)

    test_cases = problem.test_cases

    total_running_time = 0

    test_cases.each_with_index do |test_case, index|

      @test_case_path = "#{CONFIG[:base_path]}/contests/#{ccode}/#{pcode}/test_cases/#{test_case[:name]}/"
      @test_case_output_path = "#{CONFIG[:base_path]}/contests/#{ccode}/#{pcode}/test_case_outputs/#{test_case[:name]}/"
      source_path = @user_compile_path
      @submission_path = @user_compile_path + "#{test_case[:name]}/"

      if langcode == 'python'
        command = "python /source/user_source_code#{file_extensions[langcode]} < /testcase/#{test_case[:name]} > /submission/#{test_case[:name]}"
      elsif langcode == 'java'
        command = "java -cp /source/ Main < /testcase/#{test_case[:name]} > /submission/#{test_case[:name]}"
      else
        command = "/source/compiled_code < /testcase/#{test_case[:name]} > /submission/#{test_case[:name]}"
      end

      memory_specification = 536870912
      if langcode == 'java'
        memory_specification = 1677721600
      end
      container = Docker::Container.create('Cmd' => ["bash", "-c", command],'Image' => 'archit/codecracker', 'Volumes' => {"/submission" => {}, "/testcase" => {}}, 'NetworkDisabled' => true, 'Memory' => 536870912)

      container_id = container.json["Id"]

      time_start = Time.now()

      container.start("Binds"=> [ "#{source_path}:/source:rw", "#{@submission_path}:/submission:rw", "#{@test_case_path}:/testcase:ro" ])
      keep_running_flag = true


      while container.json["State"]["Running"]
        begin
          if container.top.length < 2 then
            next
          elsif container.top.length > 2
            error_flag = 'RTE'
          else
            pid = container.top[1]["PID"].to_i
            pid_new = status = max_memory_used = 0
            error_flag = nil

            begin
              memory_used = get_memory_usage(pid)
            rescue
              memory_used = 0
            end
            max_memory_used = [max_memory_used, memory_used].max

            if langcode != 'java' && max_memory_used > mlimit
              error_flag = 'MLE'
            elsif container.json["State"]["Running"] && Time.now() - DateTime.parse(container.json["State"]["StartedAt"]).to_time > tlimit
              error_flag = 'TLE'
            end
          end
          unless error_flag.nil?
            begin
              begin
                container = Docker::Container.get(container_id)
                # container.kill
                container.delete(force: true)
              rescue
                Process.kill('KILL', pid)
              end
              submission = get_submission(submission_id)
              if submission.nil?
                return
              end
              submission.update_attributes!( status_code: error_flag, error_description: error_flag )
              return
            rescue Errno::ESRCH => e
              break
            end
          end
        rescue
        end
      end
      if error_flag.nil?
        begin
          container = Docker::Container.get(container_id)
          exit_code = container.json["State"]["ExitCode"].to_i
          if exit_code != 0
            if signal_list.has_key?(exit_code)
              error_flag = 'SIG' + signal_list[exit_code]
            else
              error_flag = 'RTE'
            end
            submission = get_submission(submission_id)
            if submission.nil?
              begin
                  container = Docker::Container.get(container_id)
                  container.delete(force: true)
              rescue
              end
              return
            end
            submission.update_attributes!( status_code: error_flag, error_description: error_flag )
            return
          else
            begin
              running_time = DateTime.parse(container.json["State"]["FinishedAt"]).to_time - DateTime.parse(container.json["State"]["StartedAt"]).to_time
            rescue
              running_time = Time.now() - time_start
            end
            total_running_time += running_time
          end
        rescue
          container = nil
        end
      end

      unless test_case[:checker_is_a_code]
        submission = get_submission(submission_id)
        if submission.nil?
          begin
              container = Docker::Container.get(container_id)
              container.delete(force: true)
          rescue
          end
          return
        end
        if !check_solution_through_diff(test_case)
          submission.update_attributes!( status_code: "WA", error_description: "WA" )
          begin
              container = Docker::Container.get(container_id)
              container.delete(force: true)
          rescue
          end
          return
        end
      end

      begin
        container = Docker::Container.get(container_id)
        container.delete(force: true)
      rescue
      end

    end

    submission = get_submission(submission_id)
    if submission.nil?
      return
    end
    submission.update_attributes!( status_code: 'AC', running_time: total_running_time )
  end

  def get_memory_usage(pid)
    proc_path = "/proc/#{pid}/status"
    file_read = File.read(proc_path)
    data = stack = 0
    file_read.each_line do |line|
      vmDataInd = line.index("VmData:")
      vmStkInd = line.index("VmStk:")
      unless vmDataInd.nil?
        data = line.scanf("VmData%*s %d")[0]
      end
      unless vmStkInd.nil?
        stack = line.scanf("VmStk%*s %d")[0]
      end
    end
    return data + stack
  end

  def check_solution_through_diff(test_case)
    user_solution_path = @submission_path + test_case[:name]
    test_case_solution_path = @test_case_output_path + test_case[:name]
    diff = %x(diff -ZbB #{user_solution_path} #{test_case_solution_path})
    if $?.exitstatus.to_i != 0 || diff.length > 0
      return false
    end
    return true
  end

  def check_solution(test_case)
    user_solution_path = @submission_path + test_case[:name]
    test_case_solution_path = @test_case_output_path + test_case[:name]
    begin
      user_solution = File.read(user_solution_path)
      test_case_solution = File.read(test_case_solution_path)
    rescue
      return false
    end
    test_case_solution.lines.each_with_index do |test_line, index|
      test_token_array = test_line.strip.split()
      begin
        user_token_array = user_solution.lines[index].strip.split()
      rescue
        return false
      end
      if test_token_array != user_token_array
        return false
      end
    end

    return true
  end

  def get_submission(submission_id)
    submission = Submission.where(_id: submission_id.to_s).first
    if submission.nil? || submission[:status_code] != "PE"
      return nil
    end
    return submission
  end

end