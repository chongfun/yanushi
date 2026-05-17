class EmailConfiguration < ApplicationRecord
  belongs_to :user

  encrypts :password

  validates :imap_server, :username, :password, presence: true
  validates :imap_port, numericality: { only_integer: true, greater_than: 0 }
end
