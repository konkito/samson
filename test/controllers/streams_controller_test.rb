require_relative '../test_helper'

describe StreamsController do

  let(:project) { projects(:test) }
  let(:stage) { stages(:test_staging) }
  let(:deployer) { users(:deployer) }
  let(:command) { "echo hello" }
  let(:job) { Job.create!(command: command, project: project, user: deployer) }
  let(:deploy) { Deploy.create!(stage: stage, job: job, reference: "foo") }

  as_a_deployer do
    describe "a GET to :show" do
      it "should have an initial :started SSE and a :finished SSE" do

        skip("This somehow makes other tests like EventStreamer tests fail.")

        # Override the job retrieval in the streams controller. This way we don't have
        # to stub out all the rest of the JobExecution setup/execute/... flow.
        @fake_execution = JobExecution.new("foo", job)
        JobExecution.expects(:find_by_id).returns(@fake_execution)

        # Get the :show page to open the SSE stream
        get :show, id: job.id

        # Write some msgs to our fake TerminalExecutor stream
        @fake_execution.output.write("Hello there!\n")
        # Close the stream to denote the job finishing, which will trigger sending the :finished SSE
        @fake_execution.output.close
        response.status.must_equal(200)

        # Collect the output from the ActiveController::Live::Buffer stream
        lines = []
        response.stream.each { |l| lines << l }

        # Ensure we have at least the :started and :finished SSE msgs
        assert lines.grep(/started\ndata:/)
        assert lines.grep(/finished\ndata:/)
      end
    end
  end

end
