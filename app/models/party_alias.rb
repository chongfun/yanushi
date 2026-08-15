class PartyAlias < ApplicationRecord
  belongs_to :party

  validates :alias_name, presence: true
  validates :alias_name, uniqueness: { scope: :party_id, case_sensitive: false }

  normalizes :alias_name, with: ->(name) { name.strip }
end
