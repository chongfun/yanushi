class LeaseTenant < ApplicationRecord
  belongs_to :lease
  belongs_to :tenant
end
