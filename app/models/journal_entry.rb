class JournalEntry < ApplicationRecord
  belongs_to :user
  belongs_to :reversal_of, class_name: "JournalEntry", optional: true
  has_one :reversal, class_name: "JournalEntry", foreign_key: :reversal_of_id, dependent: :restrict_with_error
  has_many :postings, dependent: :restrict_with_error

  validates :source_type, presence: true
  validates :source_id, presence: true, numericality: { only_integer: true, greater_than: 0 }
  validates :event_type, presence: true
  validates :occurred_on, presence: true
  validates :posted_at, presence: true
  validates :source_id, uniqueness: {
    scope: %i[user_id source_type event_type],
    message: "has already been posted for this event"
  }
  validates :reversal_of_id, uniqueness: {
    allow_nil: true,
    message: "has already been reversed"
  }

  before_update :prevent_mutation
  before_destroy :prevent_mutation

  def reversed?
    reversal.present?
  end

  def reversal?
    reversal_of_id.present?
  end

  def accounting_user
    user
  end

  private

    def prevent_mutation
      errors.add(:base, "Posted journal entries are immutable")
      throw :abort
    end
end
