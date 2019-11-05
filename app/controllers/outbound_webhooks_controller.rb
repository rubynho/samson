# frozen_string_literal: true
require 'samson/integration'

class OutboundWebhooksController < ResourceController
  include CurrentProject

  before_action :authorize_project_deployer!, except: [:index]
  before_action :set_resource, only: [:show, :edit, :update, :destroy, :new, :create]

  def index
    # TODO: html with all global ... no project scope
    respond_to do |format|
      format.json { render_as_json :webhooks, @project.outbound_webhooks, nil }
    end
  end

  def create
    @project = @stage.project # for rendering of index
    super(template: 'webhooks/index')
  end

  # TODO: consider json
  def destroy
    if @stage # unlink
      link = OutboundWebhookStage.find_by!(outbound_webhook_id: params.require(:id), stage_id: @stage.id)
      link.destroy
      link.outbound_webhook.destroy # TODO: also check global
      redirect_to project_webhooks_path(@stage.project), notice: "Deleted"
    else
      # TODO: auth as admin since authorize_project_deployer! will not work
      # OutboundWebhook.find(params.require(:id)).destroy
      redirect_to outbound_webhooks_path, notice: "Deleted"
    end
  end

  private

  def resource_path
    resources_path
  end

  def resources_path
    [@project, 'webhooks']
  end

  def resource_params
    link = OutboundWebhookStage.new(stage: @stage)
    super.permit(:url, :username, :password).merge(outbound_webhook_stages: [link])
  end

  def require_project
    case action_name
    when "create"
      @stage = Stage.find(params[:outbound_webhook].delete(:stage_id))
    when "destroy"
      @stage = Stage.find(params[:stage_id])
    else
      raise
    end

    @project = @stage.project
  end
end
