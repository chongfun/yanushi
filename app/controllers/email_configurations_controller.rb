class EmailConfigurationsController < ApplicationController
  before_action :set_email_configuration

  def show
  end

  def edit
  end

  def update
    if @email_configuration.update(email_configuration_params)
      redirect_to email_configuration_path, notice: "Email configuration was successfully updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def ingest
    if @email_configuration.persisted? && @email_configuration.enabled?
      IngestPaymentEmailsJob.perform_later
      redirect_to email_configuration_path, notice: "Payment email ingestion has been started."
    else
      redirect_to email_configuration_path, alert: "Email configuration must be enabled to run ingestion."
    end
  end

  private

  def set_email_configuration
    @email_configuration = Current.user.email_configuration || Current.user.build_email_configuration
  end

  def email_configuration_params
    params.require(:email_configuration).permit(:enabled)
  end
end
