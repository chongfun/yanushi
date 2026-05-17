class EmailConfiguration < ApplicationRecord
  belongs_to :user

  encrypts :google_refresh_token, :google_access_token

  validates :gmail_address, :google_refresh_token, :google_access_token, presence: true
end
