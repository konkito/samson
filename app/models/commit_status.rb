# frozen_string_literal: true
# Used to display all warnings/failures before user actually deploys
class CommitStatus
  # See ref_status_typeahead.js for how statuses are handled
  # See https://developer.github.com/v3/repos/statuses for api details
  # - fatal is our own state that blocks deploys
  # - missing is our own state that means we could not determine the status
  STATE_PRIORITY = [:success, :pending, :missing, :failure, :error, :fatal].freeze
  UNDETERMINED = ["pending", "missing"].freeze
  CHECK_STATE = {
    error: ['action_required', 'cancelled', 'timed_out'],
    failure: ['failure'],
    success: ['success', 'neutral']
  }.freeze
  NO_STATUSES_REPORTED_RESULT = {
    state: 'pending',
    statuses: [
      {
        state: 'pending',
        description:
          "No status was reported for this commit on GitHub. See https://developer.github.com/v3/checks/ and " \
            "https://github.com/blog/1227-commit-status-api for details."
      }
    ]
  }.freeze

  def initialize(project, reference, stage: nil)
    @project = project
    @reference = reference
    @stage = stage
  end

  def state
    combined_status.fetch(:state)
  end

  def statuses
    combined_status.fetch(:statuses).map(&:to_h)
  end

  def expire_cache(commit)
    Rails.cache.delete(cache_key(commit))
  end

  private

  def combined_status
    @combined_status ||= begin
      statuses = [github_state]
      statuses += [release_status, *ref_statuses].compact if @stage
      merge_statuses(statuses)
    end
  end

  # Gets a reference's state, combining results from both the Status and Checks API
  # NOTE: reply is an api object that does not support .fetch
  def github_state
    static = @reference.match?(Build::SHA1_REGEX) || @reference.match?(Release::VERSION_REGEX)
    expires_in = ->(reply) { cache_duration(reply) }
    cache_fetch_if static, cache_key(@reference), expires_in: expires_in do
      checks_result = with_octokit_client_error_rescue { github_check }
      status_result = with_octokit_client_error_rescue { github_status }

      results_with_statuses = [checks_result, status_result].select { |result| result[:statuses].any? }

      results_with_statuses.empty? ? NO_STATUSES_REPORTED_RESULT.dup : merge_statuses(results_with_statuses)
    end
  end

  # Gets commit statuses using GitHub's check API. Currently parsing it to match status structure to better facilitate
  # transition to new API. See https://developer.github.com/v3/checks/runs/ and
  # https://developer.github.com/v3/checks/suites/ for details
  def github_check
    base_url = "repos/#{@project.repository_path}/commits/#{@reference}"
    preview_header = {Accept: 'application/vnd.github.antiope-preview+json'}

    check_suites = GITHUB.get("#{base_url}/check-suites", headers: preview_header)[:check_suites]
    checks = GITHUB.get("#{base_url}/check-runs", headers: preview_header)

    overall_state = check_suites.
      map { |suite| check_state_equivalent(suite[:conclusion]) }.
      max_by { |state| STATE_PRIORITY.index(state.to_sym) }

    statuses = checks[:check_runs].map do |check_run|
      {
        state: check_state_equivalent(check_run[:conclusion]),
        description: ApplicationController.helpers.markdown(check_run[:output][:summary]),
        context: check_run[:name],
        target_url: check_run[:html_url],
        updated_at: check_run[:started_at]
      }
    end

    {state: overall_state || 'pending', statuses: statuses}
  end

  def github_status
    GITHUB.combined_status(@project.repository_path, @reference).to_h
  end

  def merge_statuses(statuses)
    statuses[1..-1].each_with_object(statuses[0]) do |status, merged|
      merged[:state] = [merged.fetch(:state), status.fetch(:state)].max_by { |s| STATE_PRIORITY.index(s.to_sym) }
      merged.fetch(:statuses).concat(status.fetch(:statuses))
    end
  end

  def check_state_equivalent(check_conclusion)
    case check_conclusion
    when *CHECK_STATE[:success] then 'success'
    when *CHECK_STATE[:error] then 'error'
    when *CHECK_STATE[:failure] then 'failure'
    when nil then 'pending'
    else raise "Unknown Check conclusion: #{check_conclusion}"
    end
  end

  def cache_duration(github_result)
    statuses = github_result[:statuses]
    if github_result == NO_STATUSES_REPORTED_RESULT # does not have any statuses, chances are commit is new
      5.minutes # NOTE: could fetch commit locally without pulling to check it's age
    elsif (Time.now - statuses.map { |s| s[:updated_at] }.max) > 1.hour # no new updates expected
      1.day
    elsif statuses.any? { |s| UNDETERMINED.include?(s[:state]) } # expecting update shortly
      1.minute
    else # user might re-run test or success changes into failure when new status arrives
      10.minutes
    end
  end

  def cache_key(commit)
    ['commit-status', @project.id, commit]
  end

  def cache_fetch_if(condition, key, expires_in:)
    return yield unless condition

    old = Rails.cache.read(key)
    return old if old

    current = yield
    Rails.cache.write(key, current, expires_in: expires_in.call(current))
    current
  end

  # checks if other stages that deploy to the same hosts as this stage have deployed a newer release
  # @return [nil, error-state]
  def release_status
    return unless DeployGroup.enabled?
    return unless current_version = version(@reference)
    return unless higher_references = last_deployed_references.select { |n| version(n)&.> current_version }.presence

    # code above is hot ... so keep it optimized and re-fetch here only if something bad was found
    interfering_stage_ids = deploy_scope.where(reference: higher_references).pluck(:stage_id)
    interfering_stages = Stage.where(id: interfering_stage_ids).pluck(:name)

    {
      state: "error", # `pending` is also supported in deploys.js, but that seems even worse
      statuses: [{
        state: "Old Release",
        description:
          "#{higher_references.join(', ')} was deployed to deploy groups in this stage" \
          " by #{interfering_stages.join(", ")}"
      }]
    }
  end

  def ref_statuses
    statuses = []
    # Check if ref has been deployed to any non-production stages first if deploying to production
    if @stage.production? && !@stage.project.deployed_reference_to_non_production_stage?(@reference)
      statuses << {
        state: "pending",
        statuses: [{
          state: "Production Only Reference",
          description: "#{@reference} has not been deployed to a non-production stage."
        }]
      }
    end
    statuses + Samson::Hooks.fire(:ref_status, @stage, @reference).compact
  end

  def version(reference)
    return unless plain = reference[Release::VERSION_REGEX, 1]
    Gem::Version.new(plain)
  end

  # optimized to sql instead of AR fanciness to make it go from 1s -> 0.01s on our worst case stage
  def last_deployed_references
    last_deployed = deploy_scope.pluck(Arel.sql('max(deploys.id)'))
    Deploy.reorder(nil).where(id: last_deployed).pluck(Arel.sql('distinct reference'))
  end

  def deploy_scope
    @deploy_scope ||= Deploy.reorder(nil).successful.where(stage_id: @stage.influencing_stage_ids).group(:stage_id)
  end

  def with_octokit_client_error_rescue
    yield
  rescue Octokit::ClientError
    generate_error_status_and_report($!)
  end

  def generate_error_status_and_report(exception)
    error_url = ErrorNotifier.notify(exception, sync: true)
    {
      state: "missing",
      statuses: [{
        context: "Reference", # for releases/show.html.erb
        state: "missing",
        description: "There was a problem getting the status for reference '#{@reference}'." \
                       " See #{error_url} for details",
        updated_at: Time.now # needed for #cache_duration
      }]
    }
  end
end
