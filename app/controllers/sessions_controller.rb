class SessionsController < ApplicationController
  allow_unauthenticated_access only: %i[ new create ]
  rate_limit to: 10, within: 3.minutes, only: :create, with: -> { redirect_to new_session_path, alert: "Try again later." }

  def new
  end

  def create
    if user = User.authenticate_by(params.permit(:email_address, :password))
      start_new_session_for user
      redirect_to after_authentication_url
    else
      respond_to do |format|
        format.turbo_stream do
          flash.now[:alert] = "Try another email address or password."
          render turbo_stream: turbo_stream.append("flash-messages", partial: "shared/toast", locals: { type: "alert", message: flash.now[:alert] })
        end
        format.html { redirect_to new_session_path, alert: "Try another email address or password." }
      end
    end
  end

  def destroy
    terminate_session
    redirect_to new_session_path, status: :see_other
  end
end
