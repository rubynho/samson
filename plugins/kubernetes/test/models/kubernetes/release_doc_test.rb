# frozen_string_literal: true
require_relative "../../test_helper"

SingleCov.covered!

describe Kubernetes::ReleaseDoc do
  def deployment_stub(replica_count)
    {
      spec: {
        'replicas=' => replica_count
      },
      status: {
        replicas: replica_count
      }
    }
  end

  def daemonset_stub(scheduled, misscheduled)
    {
      kind: "DaemonSet",
      metadata: {
        name: 'some-project',
        namespace: 'pod1'
      },
      status: {
        currentNumberScheduled: scheduled,
        numberMisscheduled:     misscheduled
      },
      spec: {
        template: {
          spec: {
            'nodeSelector=' => nil
          }
        }
      }
    }
  end

  let(:doc) { kubernetes_release_docs(:test_release_pod_1) }
  let(:primary_template) { doc.resource_template[0] }
  let(:kube_404) { Kubeclient::ResourceNotFoundError.new(404, 2, 3) }
  let(:service_url) { "http://foobar.server/api/v1/namespaces/pod1/services/some-project" }

  before do
    configs = YAML.load_stream(read_kubernetes_sample_file('kubernetes_deployment.yml'))
    configs.each { |c| c['metadata']['namespace'] = 'pod1' }
    doc.send(:resource_template=, configs)
  end

  describe "#store_resource_template" do
    def create!
      doc.kubernetes_release.builds = [builds(:docker_build)]
      Kubernetes::ReleaseDoc.create!(
        doc.attributes.except('id', 'resource_template').merge(kubernetes_release: doc.kubernetes_release)
      )
    end

    let(:template) { Kubernetes::ReleaseDoc.new.send(:raw_template) } # makes all docs share the stubbed template

    before do
      kubernetes_fake_raw_template
      Kubernetes::TemplateFiller.any_instance.stubs(:set_image_pull_secrets) # makes an extra request we ignore
    end

    it "stores the template when creating" do
      create!.resource_template[0][:kind].must_equal 'Deployment'
    end

    it "fails to create with missing config file" do
      Kubernetes::ReleaseDoc.any_instance.unstub(:raw_template)
      GitRepository.any_instance.expects(:file_content).returns(nil) # File not found
      assert_raises(ActiveRecord::RecordInvalid) { create! }
    end

    it "adds counter to service names when using multiple services" do
      doc.kubernetes_role.update_column(:service_name, 'foo')
      template.push template[1].deep_dup # 2 Services
      create!.resource_template[1][:metadata][:name].must_equal 'foo'
      create!.resource_template[2][:metadata][:name].must_equal 'foo-2'
    end

    describe "PodDisruptionBudget" do
      it "does not add budget by default" do
        refute create!.resource_template[2]
      end

      it "adds valid relative PodDisruptionBudget when sometimes invalid is requested" do
        template.dig(0, :metadata)[:annotations] = {"samson/minAvailable": '99%'}
        create!.resource_template[2][:spec][:minAvailable].must_equal '50%'
      end

      it "fails when completely invalid is requested" do
        template.dig(0, :metadata)[:annotations] = {"samson/minAvailable": '100%'}
        assert_raises(Samson::Hooks::UserError) { create! }
      end

      it "adds absolute PodDisruptionBudget when requested" do
        template.dig(0, :metadata)[:annotations] = {"samson/minAvailable": '1'}
        create!.resource_template[2][:spec][:minAvailable].must_equal 1
      end

      describe "with relative budget" do
        before { template.dig(0, :metadata)[:annotations] = {"samson/minAvailable": '30%'} }

        it "adds relative PodDisruptionBudget" do
          Time.stubs(:now).returns(Time.parse("2018-01-01"))
          budget = create!.resource_template[2]
          budget[:spec][:minAvailable].must_equal '30%'
          budget[:metadata][:annotations][:"samson/updateTimestamp"].must_equal "2018-01-01T00:00:00Z"
          refute budget.key?(:delete)
        end

        it "can use deploy group default namespace via template filler" do
          template.dig(0, :metadata).delete :namespace
          budget = create!.resource_template[2]
          budget[:metadata][:namespace].must_equal "pod1"
        end

        it "can use custom namespace" do
          template[0][:metadata][:namespace] = "custom"
          budget = create!.resource_template[2]
          budget[:metadata][:namespace].must_equal "custom"
        end
      end

      describe "with auto-add" do
        with_env KUBERNETES_AUTO_MIN_AVAILABLE: "1"

        it "add default" do
          create!.resource_template[2][:spec][:minAvailable].must_equal 1
        end

        it "adds when first is not a Deployment" do
          template.unshift(kind: "ConfigMap", metadata: {})
          create!.resource_template[3][:spec][:minAvailable].must_equal 1
        end

        it "ignores when there is no deployment" do
          template.replace([{kind: "ConfigMap", metadata: {}}])
          refute create!.resource_template[1]
        end

        it "deletes for things that are not highly available anyway" do
          doc.replica_target = 1
          assert create!.resource_template[2][:delete]
        end

        it "can disable with disabled" do
          template.dig(0, :metadata)[:annotations] = {"samson/minAvailable": "disabled"}
          refute create!.resource_template[2]
        end
      end

      it "uses the same namespace as the resource" do
        metadata = template.dig(0, :metadata)
        metadata[:annotations] = {"samson/minAvailable": '30%'}
        metadata[:namespace] = "default"
        create!.resource_template[2][:metadata][:namespace].must_equal 'default'
      end

      it "keeps name when using custom namespace" do
        doc.kubernetes_release.project.create_kubernetes_namespace!(name: "foo")
        template.dig(0, :metadata)[:annotations] = {"samson/minAvailable": '30%'}
        create!.resource_template[2][:metadata][:name].must_equal 'some-project-rc'
      end

      it "supports multiproject" do
        metadata = template.dig(0, :metadata)
        metadata[:annotations] = {"samson/minAvailable": '30%', "samson/override_project_label": "true"}
        metadata[:labels][:project] = 'change-me'
        create!.resource_template[2][:metadata][:labels][:project].must_equal 'foo'
      end

      it "does not copy random annotations like secrets/set_via_env etc" do
        template.dig(0, :metadata)[:annotations] = {"samson/minAvailable": '30%'}
        create!.resource_template[2][:metadata][:annotations].keys.sort.must_equal [
          :"samson/deploy_url", :"samson/updateTimestamp"
        ]
      end

      it "copies keep-name so name stays in sync with the deployment" do
        template.dig(0, :metadata)[:annotations] = {"samson/minAvailable": '30%', "samson/keep_name": 'true'}
        assert create!.resource_template[2][:metadata][:annotations].key?(:"samson/keep_name")
      end

      it "deletes when set to 0" do
        template.dig(0, :metadata)[:annotations] = {"samson/minAvailable": '0'}
        create!.resource_template[2][:delete].must_equal true
      end

      it "deletes when set to 0 via relative" do
        doc.replica_target = 0
        template.dig(0, :metadata)[:annotations] = {"samson/minAvailable": '50%'}
        create!.resource_template[2][:delete].must_equal true
      end

      it "deletes when deploying with 0 replicas to delete the deployment" do
        template.dig(0, :metadata)[:annotations] = {"samson/minAvailable": '2'}
        doc.replica_target = 0
        create!.resource_template[2][:delete].must_equal true
      end

      it "fixes when creating a deadlock by setting a absolute value" do
        template.dig(0, :metadata)[:annotations] = {"samson/minAvailable": '2'}
        create!
        create!.resource_template[2][:spec][:minAvailable].must_equal 1
      end
    end
  end

  describe "#deploy" do
    let(:client) { doc.deploy_group.kubernetes_cluster.client('extensions/v1beta1') }

    it "creates" do
      # check and then create service
      stub_request(:get, service_url).to_raise(kube_404)
      stub_request(:post, "http://foobar.server/api/v1/namespaces/pod1/services").to_return(body: "{}")

      # check and then create deployment
      client.expects(:get_deployment).raises(kube_404)
      client.expects(:create_deployment).returns({})

      doc.deploy
      doc.instance_variable_get(:@previous_resources).must_equal([nil, nil]) # will not revert
    end

    it "deploys resources in DEPLOY_SORT_ORDER order" do
      configs = YAML.load_stream(read_kubernetes_sample_file('kubernetes_rbac.yml'))
      configs.each { |c| c['metadata']['namespace'] = 'pod1' if c['metadata']['namespace'].present? }
      doc.send(:resource_template=, doc.resource_template + configs)

      expected_request_order = [:serviceaccounts, :clusterroles, :clusterrolebindings, :services, :deployments]
      request_order = []
      regex = %r{
        http://foobar.server(:80)?/apis?/
        (extensions/|rbac.authorization.k8s.io/)?
        v1(beta\d)?/
        (namespaces/pod1/)?
        (\w+)
      }x
      stub_request(:get, %r{#{regex}/some-project.*}).to_raise(kube_404)
      stub_request(:post, regex).to_return do |request|
        request_order << regex.match(request.uri)[5].to_sym
        {body: "{}"}
      end

      doc.deploy
      doc.instance_variable_get(:@previous_resources).must_equal([nil, nil, nil, nil, nil]) # will not revert
      request_order.must_equal expected_request_order
    end

    it "remembers the previous deploy in case we have to revert" do
      # check service ... do nothing
      stub_request(:get, service_url).to_return(body: '{"SER":"VICE"}')
      stub_request(:put, service_url).to_return(body: '{"RE":"SOURCE"}')

      # check and update deployment
      Kubernetes::Resource::Deployment.any_instance.stubs(:ensure_not_updating_match_labels)
      client.expects(:get_deployment).returns(DE: "PLOY")
      client.expects(:update_deployment).returns("Rest client resonse")

      doc.deploy
      doc.instance_variable_get(:@previous_resources).must_equal([{SER: "VICE"}, {DE: "PLOY"}])
    end
  end

  describe '#revert' do
    it "reverts all resources" do
      doc.instance_variable_set(:@previous_resources, [{SER: "VICE"}, {DE: "PLOY"}])
      resources = doc.send(:resources)
      resources.detect { |r| r.is_a? Kubernetes::Resource::Deployment }.
        expects(:revert).with(DE: "PLOY")
      resources.detect { |r| r.is_a? Kubernetes::Resource::Service }.
        expects(:revert).with(SER: "VICE")
      doc.revert
    end

    it "fails when called out of order" do
      assert_raises(RuntimeError) { doc.revert }
    end
  end

  describe "#validate_config_file" do
    let(:doc) { kubernetes_release_docs(:test_release_pod_1).dup } # validate_config_file is always called on a new doc

    it "is valid" do
      kubernetes_fake_raw_template
      assert_valid doc
    end

    it "is invalid without template" do
      GitRepository.any_instance.expects(:file_content).returns(nil)
      refute_valid doc
      doc.errors.full_messages.must_equal(
        ["Kubernetes release does not contain config file 'kubernetes/app_server.yml'"]
      )
    end

    it "reports detailed errors when invalid" do
      GitRepository.any_instance.expects(:file_content).returns("foo: bar")
      refute_valid doc
    end

    it "does nothing when no role is set" do
      doc.kubernetes_role = nil
      refute_valid doc
      doc.errors.full_messages.must_equal(
        ["Kubernetes role must exist", "Kubernetes role can't be blank"]
      )
    end
  end

  describe "#desired_pod_count" do
    it "delegates to resource" do
      doc.desired_pod_count.must_equal 2
    end
  end

  describe "#prerequisite?" do
    it "delegates to resources" do
      refute doc.prerequisite?
      doc.resources.first.stubs(:prerequisite?).returns(true)
      assert doc.prerequisite?
    end
  end

  # tested in depth from deploy_executor.rb since it has to work when called with it's local ReleaseDoc setup
  describe "#verify_template" do
    it "can run with a new release doc" do
      kubernetes_fake_raw_template
      doc.verify_template
    end
  end

  describe "#blue_green_color" do
    before { doc.kubernetes_release.blue_green_color = "green" }

    it "is releases color when blue-green" do
      doc.kubernetes_role.blue_green = true
      assert doc.blue_green_color.must_equal "green"
    end

    it "is nil when not blue-green" do
      refute doc.blue_green_color
    end
  end

  describe '#deploy_group_role' do
    it "returns an instance of a DeployGroupRole" do
      doc.deploy_group_role.must_be_instance_of Kubernetes::DeployGroupRole
    end

    it "can be set" do
      doc.deploy_group_role = Kubernetes::DeployGroupRole.first
      assert_sql_queries(0) { assert doc.deploy_group_role }
    end
  end
end
