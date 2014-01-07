class DeploysController < ApplicationController
  rescue_from ActiveRecord::RecordNotFound do |error|
    flash[:error] = "Job not found."
    redirect_to root_path
  end

  before_filter :authorize_deployer!, only: [:create, :update, :destroy]
  before_filter :find_project
  before_filter :find_deploy, only: [:show, :update, :destroy]

  def index
    @deploys = Deploy.limit(10).order("created_at DESC")
  end

  def active
    @deploys = Deploy.active.limit(10).order("created_at DESC")

    render :index
  end

  def create
    commit = deploy_params[:commit]
    stage = @project.stages.find(deploy_params[:stage_id])
    deploy_service = DeployService.new(@project, stage, current_user)
    deploy = deploy_service.deploy!(commit)

    redirect_to project_deploy_path(@project, deploy)
  end

  def show
  end

  def destroy
    if !@deploy.started_by?(current_user)
      head :forbidden
    else
      @deploy.stop!

      head :ok
    end
  end

  protected

  def deploy_params
    params.require(:deploy).permit(:commit, :stage_id)
  end

  def find_project
    @project = Project.find(params[:project_id])
  end

  def find_deploy
    @deploy = Deploy.find(params[:id])
  end
end
