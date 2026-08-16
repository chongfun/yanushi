class Session < ApplicationRecord
  belongs_to :user

  def accounting_user
    user
  end
end
