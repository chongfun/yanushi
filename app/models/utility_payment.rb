class UtilityPayment < ApplicationRecord
  belongs_to :tenant
  belongs_to :rental_property
end
