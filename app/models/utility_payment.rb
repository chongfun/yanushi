class UtilityPayment < ApplicationRecord
  belongs_to :lease
  belongs_to :expense, optional: true
end
