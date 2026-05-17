class PaymentEmailsController < ApplicationController
  def index
    @payment_emails = Current.user.payment_emails.order(created_at: :desc)
  end

  def show
    @payment_email = Current.user.payment_emails.find(params[:id])
  end
end
