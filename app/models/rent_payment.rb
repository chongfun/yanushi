class RentPayment < ApplicationRecord
  belongs_to :scheduled_rent

  after_create  :mark_scheduled_rent_paid
  after_destroy :mark_scheduled_rent_unpaid

  private

  def mark_scheduled_rent_paid
    scheduled_rent.update_column(:paid, true)
  end

  def mark_scheduled_rent_unpaid
    scheduled_rent.update_column(:paid, false)
  end
end
