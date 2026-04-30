class Lease < ApplicationRecord
  belongs_to :rental_property
  has_many :lease_tenants, dependent: :destroy
  has_many :tenants, through: :lease_tenants
  has_many :scheduled_rents, dependent: :destroy

  enum :lease_type, { month_to_month: 0, term: 1 }

  after_create :generate_scheduled_rents

  private

  def generate_scheduled_rents
    end_date = month_to_month? ? commencement_date + 11.months : termination_date
    (commencement_date.year..end_date.year).each do |year|
      ScheduledRentsGenerator.new(self, year, end_date: end_date).call
    end
  end
end
