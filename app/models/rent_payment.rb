class RentPayment < ApplicationRecord
  belongs_to :scheduled_rent

  after_save    :update_scheduled_rent_status
  after_destroy :update_scheduled_rent_status

  private

  def update_scheduled_rent_status
    # Check if total payments cover the scheduled amount
    total_paid = scheduled_rent.rent_payments.sum(:amount)
    scheduled_rent.update_column(:paid, total_paid >= scheduled_rent.amount)
  end
end
