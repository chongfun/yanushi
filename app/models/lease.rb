class Lease < ApplicationRecord
  belongs_to :rental_property
  has_many :lease_tenants, dependent: :destroy
  has_many :tenants, through: :lease_tenants
  has_many :scheduled_rents, dependent: :destroy

  enum :lease_type, { month_to_month: 0, term: 1 }

  after_create :generate_scheduled_rents

  private

  def generate_scheduled_rents
    amount_per_month = annual_rental_amount / 12.0

    months_to_generate = if month_to_month?
      12
    else
      # calculate months between commencement and termination
      (termination_date.year * 12 + termination_date.month) - (commencement_date.year * 12 + commencement_date.month)
    end

    months_to_generate.times do |i|
      scheduled_rents.create!(
        amount: amount_per_month,
        due_date: commencement_date + i.months
      )
    end
  end
end
