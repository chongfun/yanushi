class PropertyTaxProfile < ApplicationRecord
  belongs_to :property

  attr_readonly :tax_year

  SCHEDULE_E_PROPERTY_TYPES = %w[
    single_family_residence
    multi_family_residence
    vacation_short_term_rental
    commercial
    land
    self_rental
    other
  ].freeze

  enum :schedule_e_property_type, SCHEDULE_E_PROPERTY_TYPES.index_by(&:itself), prefix: false, validate: true

  validates :tax_year, presence: true,
                       numericality: {
                         only_integer: true,
                         greater_than_or_equal_to: TaxReporting::TaxYear::MIN_YEAR,
                         less_than_or_equal_to: TaxReporting::TaxYear::MAX_YEAR
                       },
                       uniqueness: { scope: :property_id }
  validates :schedule_e_property_type, presence: true
  validates :other_description, presence: true, if: :other?
  validate :validate_other_description_blank_unless_other

  normalizes :other_description, with: ->(desc) { desc&.strip.presence }

  IRS_CODE_MAP = {
    "single_family_residence" => 1,
    "multi_family_residence" => 2,
    "vacation_short_term_rental" => 3,
    "commercial" => 4,
    "land" => 5,
    "self_rental" => 7,
    "other" => 8
  }.freeze

  IRS_LABEL_MAP = {
    "single_family_residence" => "Single-Family Residence",
    "multi_family_residence" => "Multi-Family Residence",
    "vacation_short_term_rental" => "Vacation / Short-Term Rental",
    "commercial" => "Commercial",
    "land" => "Land",
    "self_rental" => "Self-Rental",
    "other" => "Other"
  }.freeze

  def schedule_e_code
    IRS_CODE_MAP[schedule_e_property_type.to_s] || 8
  end

  def schedule_e_code_description
    code = schedule_e_code
    label = IRS_LABEL_MAP[schedule_e_property_type.to_s] || "Other"
    if other? && other_description.present?
      "#{code} — #{label}: #{other_description}"
    else
      "#{code} — #{label}"
    end
  end

  def accounting_user
    property&.user
  end

  private

    def validate_other_description_blank_unless_other
      return if other?

      if other_description.present?
        errors.add(:other_description, "must be blank when property type is not other")
      end
    end
end
