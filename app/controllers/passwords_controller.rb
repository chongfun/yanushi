class PasswordsController < ApplicationController
  allow_unauthenticated_access
  before_action :set_user_by_token, only: %i[ edit update ]
  rate_limit to: 10, within: 3.minutes, only: :create, with: -> { redirect_to new_password_path, alert: "Try again later." }

  def new
  end

  def create
    if user = User.find_by(email_address: params[:email_address])
      PasswordsMailer.reset(user).deliver_later
    end

    respond_to do |format|
      format.turbo_stream do
        flash.now[:notice] = "Password reset instructions sent (if user with that email address exists)."
        render turbo_stream: turbo_stream.append("flash-messages", partial: "shared/toast", locals: { type: "notice", message: flash.now[:notice] })
      end
      format.html { redirect_to new_session_path, notice: "Password reset instructions sent (if user with that email address exists)." }
    end
  end

  def edit
  end

  def update
    if @user.update(params.permit(:password, :password_confirmation))
      @user.sessions.destroy_all
      redirect_to new_session_path, notice: "Password has been reset."
    else
      respond_to do |format|
        format.turbo_stream do
          flash.now[:alert] = "Passwords did not match."
          render turbo_stream: turbo_stream.append("flash-messages", partial: "shared/toast", locals: { type: "alert", message: flash.now[:alert] })
        end
        format.html { redirect_to edit_password_path(params[:token]), alert: "Passwords did not match." }
      end
    end
  end

  private
    def set_user_by_token
      @user = User.find_by_password_reset_token!(params[:token])
    rescue ActiveSupport::MessageVerifier::InvalidSignature
      redirect_to new_password_path, alert: "Password reset link is invalid or has expired."
    end
end
