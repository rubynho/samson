# frozen_string_literal: true
require 'shellwords'

class JobExecution
  extend ::Samson::PerformanceTracer::Tracers

  cattr_accessor(:cancel_timeout, instance_writer: false) { 15.seconds }

  attr_reader :output, :reference, :job, :viewers, :executor

  delegate :id, :deploy, to: :job
  delegate :pid, :pgid, to: :executor

  def initialize(reference, job, &block)
    @job = job
    @reference = reference
    @execution_block = block

    @output = OutputBuffer.new
    @executor = TerminalExecutor.new(
      @output,
      verbose: true,
      deploy: job.deploy,
      project: job.project,
      timeout: Rails.application.config.samson.deploy_timeout,
      cancel_timeout: cancel_timeout
    )
    @stage = @job.deploy&.stage
    @viewers = JobViewers.new(@output)
    @start_callbacks = []
    @finish_callbacks = []
    @finished = false

    @repository = @job.project.repository
    @repository.executor = @executor
    @repository.full_checkout = true if @stage&.full_checkout
  end

  def wait_for_external_setup
    interval = 5
    poll_wait_time = trigger_wait_time = 30
    status_poll = nil
    success = false

    setup_hook = @stage.external_setup_hook
    payload = stage_context_env

    return true if setup_hook.nil?

    @output.write("Trigger external setup through #{setup_hook.endpoint} with payload #{payload}\n")

    until trigger_wait_time < 0 do
      trigger_wait_time -= interval

      response = Faraday.post(setup_hook.endpoint, payload.to_json) do |req|
        req.options.timeout = req.options.open_timeout = 1
        req.headers['Authorization'] = "token #{setup_hook.auth_token}"
        req.headers['Content-Type'] = 'application/json'
      end
      if response.status == 200
        body = JSON.parse response.body
        status_poll = body['status_poll_url'] || nil
      end

      break unless status_poll.nil?
      sleep interval
    end

    return false if status_poll.nil?

    until poll_wait_time < 0 do
      poll_wait_time -= interval

      response = Faraday.get(status_poll) do |req|
        req.options.timeout = req.options.open_timeout = 1
      end
      if response.status == 200
        body = JSON.parse response.body
        success = (body['status'] == 'success')
      end

      break if success
      sleep interval
    end

    return success
  end

  def perform
    @output.write('', :started)
    @start_callbacks.each(&:call)
    @job.running!

    success = make_tempdir do |dir|
      raise "External Setup Failed" unless wait_for_external_setup

      return @job.errored! unless setup(dir)

      if @execution_block
        @execution_block.call(self, dir)
      else
        execute(dir)
      end
    end

    success = Samson::Hooks.fire(:validate_deploy, @job.deploy, self).all? if @job.deploy && success

    if success
      @job.succeeded!
    else
      @job.failed!
    end
  rescue JobQueue::Cancel
    @job.cancelling!
    raise
  rescue => e
    error!(e)
  ensure
    finish
    @job.cancelled! if @job.cancelling?
  end
  add_asynchronous_tracer :perform,
    category: :task,
    params: '{ job_id: id, project: job.project&.name, reference: reference }'

  # Used on queued jobs when shutting down
  # so that the stream sockets are closed
  def close
    @output.write('', :reloaded)
    @output.close
  end

  def on_start(&block)
    @start_callbacks << block
  end

  def on_finish
    @finish_callbacks << -> do
      begin
        yield
      rescue => e
        message = "Finish hook failed: #{e.message}"
        output.puts message
        Samson::ErrorNotifier.notify(e, error_message: message, parameters: {job_url: job.url})
      end
    end
  end

  def descriptor
    "#{job.project.name} - #{reference}"
  end

  # also used for docker builds
  def base_commands(dir, env = {})
    artifact_cache_dir = File.join(@job.project.repository.repo_cache_dir, "artifacts")
    FileUtils.mkdir_p(artifact_cache_dir)
    env[:CACHE_DIR] = artifact_cache_dir

    commands = env.map do |key, value|
      "export #{key}=#{value.to_s.shellescape}"
    end

    ["cd #{dir}"].concat commands
  end

  private

  def error!(exception)
    puts_if_present "JobExecution failed: #{exception.message}"
    error_url = report_error(exception)
    @output.puts "Error URL: #{error_url}" if error_url
    puts_if_present render_backtrace(exception)
    @job.errored! if @job.active?
  end

  def finish
    @finish_callbacks.each(&:call)

    @output.write('', :finished)
    @output.close

    @job.update_column :output, TerminalOutputScanner.new(@output).to_s
  end

  def execute(dir)
    Rails.logger.info("Executing Job Execution #{id}")
    Samson::Hooks.fire(:after_deploy_setup, dir, @job, @output, @reference)

    @output.write("\n# Executing deploy\n")
    @output.write("# Deploy URL: #{@job.deploy.url}\n") if @job.deploy

    cmds = commands(dir)
    payload = {
      stage: (@stage&.name || "none"),
      project: @job.project.name,
      production: @stage&.production?
    }

    Samson::TimeSum.instrument "execute_job.samson", payload do
      payload[:success] =
        if kubernetes?
          Kubernetes::DeployExecutor.new(@job, @output).execute
        else
          @executor.execute(*cmds)
        end
    end
  end

  # ideally the plugin should handle this, but that was even hackier
  def kubernetes?
    defined?(SamsonKubernetes::Engine) && @stage&.kubernetes
  end

  def setup(dir)
    Rails.logger.info("Setting up Job Execution #{id}")
    return unless resolve_ref_to_commit

    kubernetes? || @repository.checkout_workspace(dir, @reference)
  end

  def resolve_ref_to_commit
    commit = @repository.commit_from_ref(@reference)
    tag = @repository.fuzzy_tag_from_ref(@reference)
    if commit
      @job.update_git_references!(commit: commit, tag: tag)

      @output.puts("Commit: #{commit}")
      true
    else
      @output.puts("Could not find commit for #{@reference}")
      false
    end
  end

  def stage_context_env
    return @stage_context_env unless @stage_context_env.nil?

    @stage_context_env = {
      DEPLOY_ID: @job.deploy&.id || @job.id,
      DEPLOY_URL: @job.url,
      DEPLOYER: @job.user.email,
      DEPLOYER_EMAIL: @job.user.email,
      DEPLOYER_NAME: @job.user.name,
      REFERENCE: @reference,
      REVISION: @job.commit,
      TAG: (@job.tag || @job.commit),

      # for shared notification scripts
      PROJECT_NAME: @job.project.name,
      PROJECT_PERMALINK: @job.project.permalink,
      PROJECT_REPOSITORY: @job.project.repository_url
    }

    if @stage
      @stage_context_env[:STAGE] = @stage.permalink

      group_names = @stage.deploy_groups.pluck(:env_value).join(" ")
      @stage_context_env[:DEPLOY_GROUPS] = group_names if group_names.present?
    end

    @stage_context_env
  end

  def commands(dir)
    env = stage_context_env

    env.merge!(make_builds_available) if @stage&.builds_in_environment

    Samson::Hooks.fire(:deploy_execution_env, @job.deploy).compact.inject(env, :merge!) if @job.deploy
    base_commands(dir, env) + @job.commands
  end

  def make_builds_available
    # wait for builds to finish
    builds = build_finder.ensure_succeeded_builds

    # pre-download the necessary images in case they are not public
    ImageBuilder.local_docker_login do |login_commands|
      @executor.quiet do
        @executor.execute(
          *login_commands,
          *builds.map { |build| @executor.verbose_command("docker pull #{build.docker_repo_digest.shellescape}") }
        )
      end
    end

    # make repo-digests available to stage commands
    builds.map do |build|
      name = build.dockerfile || build.image_name
      name = name.gsub(/[^A-Za-z\d_]/, "_") # IEEE Std 1003.1-2001 A-Z, digits, '_' (+ a-z for backwards compatibility)
      ["BUILD_FROM_#{name}", build.docker_repo_digest]
    end.to_h
  end

  # show full errors if we show exceptions
  def render_backtrace(exception)
    return unless Rails.application.config.consider_all_requests_local
    backtrace = Rails.backtrace_cleaner.filter(exception.backtrace).first(10)
    backtrace << '...'
    backtrace.join("\n")
  end

  def report_error(exception)
    return if exception.is_a?(Samson::Hooks::UserError) # do not spam us with users issues

    Samson::ErrorNotifier.notify(
      exception,
      error_message: exception.message,
      parameters: {job_id: @job.id},
      sync: true
    )
  end

  def puts_if_present(message)
    @output.puts message if message
  end

  def build_finder
    @build_finder ||= Samson::BuildFinder.new(@output, @job, @reference)
  end

  # TODO: @repository.checkout_workspace should manage the tempdir and prune after
  def make_tempdir
    dir = Dir.mktmpdir("samson-#{@job.project.permalink}-#{@job.id}")
    yield dir
  ensure
    if dir
      FileUtils.rm_rf dir # mktmpdir with block often raised errors when tempfolder got removed early
      @repository.prune_worktree
    end
  end
end
