# Generates a filled IRS Schedule E (Form 1040) PDF for a given property and tax year.
#
# Usage:
#   pdf_bytes = ScheduleEGenerator.new(property, 2025).call
#   send_data pdf_bytes, filename: "schedule_e.pdf", type: "application/pdf"
class ScheduleEGenerator
  # PDF field mappings for Schedule E Part I (Page 1) - 2023-present
  MAP_2023_PRESENT = {
    name:                              "topmostSubform[0].Page1[0].f1_1[0]",
    ssn:                               "topmostSubform[0].Page1[0].f1_2[0]",
    property_address:                  "topmostSubform[0].Page1[0].Table_Line1a[0].RowA[0].f1_3[0]",
    property_type:                     "topmostSubform[0].Page1[0].Table_Line1b[0].RowA[0].f1_6[0]",
    other_type_description:            "topmostSubform[0].Page1[0].f1_15[0]",
    rents_received:                    "topmostSubform[0].Page1[0].Table_Income[0].Line3[0].f1_16[0]",
    advertising:                       "topmostSubform[0].Page1[0].Table_Expenses[0].Line5[0].f1_22[0]",
    auto_and_travel:                   "topmostSubform[0].Page1[0].Table_Expenses[0].Line6[0].f1_25[0]",
    cleaning_and_maintenance:          "topmostSubform[0].Page1[0].Table_Expenses[0].Line7[0].f1_28[0]",
    commissions:                       "topmostSubform[0].Page1[0].Table_Expenses[0].Line8[0].f1_31[0]",
    insurance:                         "topmostSubform[0].Page1[0].Table_Expenses[0].Line9[0].f1_34[0]",
    legal_and_other_professional_fees: "topmostSubform[0].Page1[0].Table_Expenses[0].Line10[0].f1_37[0]",
    management_fees:                   "topmostSubform[0].Page1[0].Table_Expenses[0].Line11[0].f1_40[0]",
    mortgage_interest:                 "topmostSubform[0].Page1[0].Table_Expenses[0].Line12[0].f1_43[0]",
    other_interest:                    "topmostSubform[0].Page1[0].Table_Expenses[0].Line13[0].f1_46[0]",
    repairs:                           "topmostSubform[0].Page1[0].Table_Expenses[0].Line14[0].f1_49[0]",
    supplies:                          "topmostSubform[0].Page1[0].Table_Expenses[0].Line15[0].f1_52[0]",
    taxes:                             "topmostSubform[0].Page1[0].Table_Expenses[0].Line16[0].f1_55[0]",
    utilities:                         "topmostSubform[0].Page1[0].Table_Expenses[0].Line17[0].f1_58[0]",
    depreciation_expense:              "topmostSubform[0].Page1[0].Table_Expenses[0].Line18[0].f1_61[0]",
    line_19_description:               "topmostSubform[0].Page1[0].Table_Expenses[0].Line19[0].f1_64[0]",
    other:                             "topmostSubform[0].Page1[0].Table_Expenses[0].Line19[0].f1_65[0]",
    total_expenses:                    "topmostSubform[0].Page1[0].Table_Expenses[0].Line20[0].f1_68[0]",
    net_income:                        "topmostSubform[0].Page1[0].Table_Expenses[0].Line21[0].f1_71[0]",
    net_loss:                          "topmostSubform[0].Page1[0].Table_Expenses[0].Line22[0].f1_74[0]",
    line_23a:                          "topmostSubform[0].Page1[0].f1_77[0]",
    line_23b:                          "topmostSubform[0].Page1[0].f1_78[0]",
    line_23c:                          "topmostSubform[0].Page1[0].f1_79[0]",
    line_23d:                          "topmostSubform[0].Page1[0].f1_80[0]",
    line_23e:                          "topmostSubform[0].Page1[0].f1_81[0]",
    line_24:                           "topmostSubform[0].Page1[0].f1_82[0]",
    line_25:                           "topmostSubform[0].Page1[0].f1_83[0]",
    line_26:                           "topmostSubform[0].Page1[0].f1_84[0]"
  }.freeze

  # 2022 uses zero-padding for f1_01 through f1_09
  MAP_2022 = MAP_2023_PRESENT.merge({
    name:             "topmostSubform[0].Page1[0].f1_01[0]",
    ssn:              "topmostSubform[0].Page1[0].f1_02[0]",
    property_address: "topmostSubform[0].Page1[0].Table_Line1a[0].RowA[0].f1_03[0]",
    property_type:    "topmostSubform[0].Page1[0].Table_Line1b[0].RowA[0].f1_06[0]"
  }).freeze

  # 2019-2021 structural changes
  MAP_2019_2021 = MAP_2023_PRESENT.merge({
    property_address: "topmostSubform[0].Page1[0].Line1[0].Table1a[0].RowA[0].f1_3[0]",
    property_type:    "topmostSubform[0].Page1[0].Line1[0].Table1b[0].RowA[0].f1_6[0]",
    rents_received:   "topmostSubform[0].Page1[0].Table_Income[0].Income[0].Line3[0].f1_16[0]"
  }).freeze

  # 2016-2018 shifts
  MAP_2016_2018 = {
    name:                              "topmostSubform[0].Page1[0].f1_1[0]",
    ssn:                               "topmostSubform[0].Page1[0].f1_2[0]",
    property_address:                  "topmostSubform[0].Page1[0].Line1[0].Table1a[0].RowA[0].f1_3[0]",
    property_type:                     "topmostSubform[0].Page1[0].Line1[0].Table1b[0].RowA[0].f1_6[0]",
    other_type_description:            "topmostSubform[0].Page1[0].f1_15[0]",
    rents_received:                    "topmostSubform[0].Page1[0].Table_Income[0].Income[0].Line3[0].f1_16[0]",
    advertising:                       "topmostSubform[0].Page1[0].Table_Expenses[0].Line5[0].f1_28[0]",
    auto_and_travel:                   "topmostSubform[0].Page1[0].Table_Expenses[0].Line6[0].f1_34[0]",
    cleaning_and_maintenance:          "topmostSubform[0].Page1[0].Table_Expenses[0].Line7[0].f1_40[0]",
    commissions:                       "topmostSubform[0].Page1[0].Table_Expenses[0].Line8[0].f1_46[0]",
    insurance:                         "topmostSubform[0].Page1[0].Table_Expenses[0].Line9[0].f1_52[0]",
    legal_and_other_professional_fees: "topmostSubform[0].Page1[0].Table_Expenses[0].Line10[0].f1_58[0]",
    management_fees:                   "topmostSubform[0].Page1[0].Table_Expenses[0].Line11[0].f1_64[0]",
    mortgage_interest:                 "topmostSubform[0].Page1[0].Table_Expenses[0].Line12[0].f1_70[0]",
    other_interest:                    "topmostSubform[0].Page1[0].Table_Expenses[0].Line13[0].f1_76[0]",
    repairs:                           "topmostSubform[0].Page1[0].Table_Expenses[0].Line14[0].f1_82[0]",
    supplies:                          "topmostSubform[0].Page1[0].Table_Expenses[0].Line15[0].f1_88[0]",
    taxes:                             "topmostSubform[0].Page1[0].Table_Expenses[0].Line16[0].f1_94[0]",
    utilities:                         "topmostSubform[0].Page1[0].Table_Expenses[0].Line17[0].f1_100[0]",
    depreciation_expense:              "topmostSubform[0].Page1[0].Table_Expenses[0].Line18[0].f1_106[0]",
    line_19_description:               "topmostSubform[0].Page1[0].Table_Expenses[0].Line19[0].f1_112[0]",
    other:                             "topmostSubform[0].Page1[0].Table_Expenses[0].Line19[0].f1_113[0]",
    total_expenses:                    "topmostSubform[0].Page1[0].Table_Expenses[0].Line20[0].f1_119[0]",
    net_income:                        "topmostSubform[0].Page1[0].Table_Expenses[0].Line21[0].f1_125[0]",
    net_loss:                          "topmostSubform[0].Page1[0].Table_Expenses[0].Line22[0].f1_131[0]",
    line_23a:                          "topmostSubform[0].Page1[0].f1_137[0]",
    line_23b:                          "topmostSubform[0].Page1[0].f1_139[0]",
    line_23c:                          "topmostSubform[0].Page1[0].f1_141[0]",
    line_23d:                          "topmostSubform[0].Page1[0].f1_143[0]",
    line_23e:                          "topmostSubform[0].Page1[0].f1_145[0]",
    line_24:                           "topmostSubform[0].Page1[0].f1_147[0]",
    line_25:                           "topmostSubform[0].Page1[0].f1_149[0]",
    line_26:                           "topmostSubform[0].Page1[0].f1_151[0]"
  }.freeze

  # 2012-2015 base layout
  BASE_2012_2015 = {
    name:                              "topmostSubform[0].Page1[0].p1-t1[0]",
    ssn:                               "topmostSubform[0].Page1[0].p1-t2[0]",
    property_address:                  "topmostSubform[0].Page1[0].Line1[0].Pg1Table1a[0].a[0].p1-t5[0]",
    property_type:                     "topmostSubform[0].Page1[0].Line1[0].Pg1Table1b[0].a[0].p1-t52[0]",
    other_type_description:            "topmostSubform[0].Page1[0].p1-t515[0]",
    advertising:                       "topmostSubform[0].Page1[0].Pg1Table3[0].Line5[0].p1-t516[0]",
    auto_and_travel:                   "topmostSubform[0].Page1[0].Pg1Table3[0].Line6[0].p1-t33[0]",
    cleaning_and_maintenance:          "topmostSubform[0].Page1[0].Pg1Table3[0].Line7[0].p1-t39[0]",
    commissions:                       "topmostSubform[0].Page1[0].Pg1Table3[0].Line8[0].p1-t45[0]",
    insurance:                         "topmostSubform[0].Page1[0].Pg1Table3[0].Line9[0].p1-t51[0]",
    legal_and_other_professional_fees: "topmostSubform[0].Page1[0].Pg1Table3[0].Line10[0].p1-t57[0]",
    management_fees:                   "topmostSubform[0].Page1[0].Pg1Table3[0].Line11[0].p1-t63[0]",
    mortgage_interest:                 "topmostSubform[0].Page1[0].Pg1Table3[0].Line12[0].p1-t69[0]",
    other_interest:                    "topmostSubform[0].Page1[0].Pg1Table3[0].Line13[0].p1-t77[0]",
    repairs:                           "topmostSubform[0].Page1[0].Pg1Table3[0].Line14[0].p1-t83[0]",
    supplies:                          "topmostSubform[0].Page1[0].Pg1Table3[0].Line15[0].p1-t89[0]",
    taxes:                             "topmostSubform[0].Page1[0].Pg1Table3[0].Line16[0].p1-t95[0]",
    utilities:                         "topmostSubform[0].Page1[0].Pg1Table3[0].Line17[0].p1-t101[0]",
    depreciation_expense:              "topmostSubform[0].Page1[0].Pg1Table3[0].Line18[0].p1-t150[0]",
    line_19_description:               "topmostSubform[0].Page1[0].Pg1Table3[0].Line19[0].p1-t107[0]",
    other:                             "topmostSubform[0].Page1[0].Pg1Table3[0].Line19[0].p1-t510[0]",
    total_expenses:                    "topmostSubform[0].Page1[0].Pg1Table3[0].Line20[0].p1-t158[0]",
    net_income:                        "topmostSubform[0].Page1[0].Pg1Table3[0].Line21[0].p1-t164[0]",
    net_loss:                          "topmostSubform[0].Page1[0].Pg1Table3[0].Line22[0].p1-t170[0]",
    line_23a:                          "topmostSubform[0].Page1[0].p1-t505[0]",
    line_23b:                          "topmostSubform[0].Page1[0].p1-t504[0]",
    line_23c:                          "topmostSubform[0].Page1[0].p1-t176[0]",
    line_23d:                          "topmostSubform[0].Page1[0].p1-t177[0]",
    line_23e:                          "topmostSubform[0].Page1[0].p1-t508[0]",
    line_24:                           "topmostSubform[0].Page1[0].p1-t509[0]",
    line_25:                           "topmostSubform[0].Page1[0].p1-t510[0]",
    line_26:                           "topmostSubform[0].Page1[0].p1-t511[0]"
  }.freeze

  MAP_2014_2015 = BASE_2012_2015.merge({
    rents_received: "topmostSubform[0].Page1[0].Pg1Table2[0].#subform[1].Line3[0].p1-t11[0]"
  }).freeze

  MAP_2013 = BASE_2012_2015.merge({
    rents_received: "topmostSubform[0].Page1[0].Pg1Table2[0].#subform[1].Line3[1].p1-t11[0]"
  }).freeze

  MAP_2012 = BASE_2012_2015.merge({
    rents_received: "topmostSubform[0].Page1[0].Pg1Table2[0].Line3[0].p1-t11[0]"
  }).freeze

  MAP_2011 = BASE_2012_2015.merge({
    property_address:    "topmostSubform[0].Page1[0].Pg1Table1[0].a[0].p1-t5[0]",
    property_type:       "topmostSubform[0].Page1[0].Pg1Table1[0].a[0].p1-t6[0]",
    rents_received:      "topmostSubform[0].Page1[0].Pg1Table2[0].Line3a[0].p1-t11[0]",
    line_19_description: "topmostSubform[0].Page1[0].Pg1Table3[0].Line19[0].p1-t107[0]",
    other:               "topmostSubform[0].Page1[0].Pg1Table3[0].Line19[0].p1-t108[0]"
  }).freeze

  # Maps Expense model categories to Schedule E line item keys.
  CATEGORY_TO_FIELD = {
    "advertising"              => :advertising,
    "auto_and_travel"          => :auto_and_travel,
    "cleaning_and_maintenance" => :cleaning_and_maintenance,
    "commissions"              => :commissions,
    "insurance"                => :insurance,
    "legal_and_professional"   => :legal_and_other_professional_fees,
    "management"               => :management_fees,
    "mortgage_interest"        => :mortgage_interest,
    "other_interest"           => :other_interest,
    "repairs"                  => :repairs,
    "supplies"                 => :supplies,
    "taxes"                    => :taxes,
    "utilities"                => :utilities,
    "other"                    => :other
  }.freeze

  class TemplateMissingError < StandardError; end
  class TaxProfileRequiredError < StandardError; end
  class TaxReviewRequiredError < StandardError; end

  def self.template_available?(year)
    path = Rails.root.join("app/assets/pdfs/f1040se--#{year.to_i}.pdf")
    File.exist?(path)
  end

  def initialize(property, year = Date.current.year)
    @property = property
    @tax_year_obj = TaxReporting::TaxYear.parse(year, default: Date.current.year) || TaxReporting::TaxYear.new(Date.current.year)
    @year = @tax_year_obj.to_i
  end

  def call
    unless schedule_e_result.tax_profile_configured?
      raise TaxProfileRequiredError, "Tax classification must be configured for #{@year} before generating Schedule E PDF"
    end

    if schedule_e_result.unresolved_review_items.any?
      raise TaxReviewRequiredError, "Schedule E PDF cannot be generated while #{schedule_e_result.unresolved_review_items.size} unresolved review item(s) exist for #{@property.address} in #{@year}"
    end

    require "hexapdf"

    doc = HexaPDF::Document.open(template_path)
    form = doc.acro_form

    fill_property_info(form)
    fill_income(form)
    fill_expenses(form)
    fill_totals(form)

    append_other_expenses_statement(doc)

    io = StringIO.new("".b)
    doc.write(io)
    io.string
  end

  private

  def fill_property_info(form)
    set_field(form, :property_address, @property.address)
    profile = schedule_e_result.tax_profile
    return unless profile

    set_field(form, :property_type, profile.schedule_e_code.to_s)
    if profile.schedule_e_code == 8 && profile.other_description.present?
      set_field(form, :other_type_description, profile.other_description)
    end
    # Fair rental days and personal use days remain blank on single-property worksheet.
  end

  def fill_income(form)
    set_field(form, :rents_received, format_amount(rents_received))
  end

  def fill_expenses(form)
    expenses_by_category.each do |category, amount|
      field_key = CATEGORY_TO_FIELD[category]
      next unless field_key

      set_field(form, field_key, format_amount(amount))
    end

    if expenses_by_category["other"]&.nonzero? || schedule_e_result.other_expense_details.any?
      desc = line_19_other_description
      set_field(form, :line_19_description, desc) if desc.present?
    end
  end

  def line_19_other_description
    descriptions = schedule_e_result.other_expense_details.map(&:description).map(&:presence).compact.uniq
    return nil if descriptions.empty?

    joined = descriptions.join(", ")
    if joined.length <= 36
      joined
    else
      "See attached statement"
    end
  end

  def append_other_expenses_statement(doc)
    return unless line_19_other_description == "See attached statement"

    all_details = schedule_e_result.other_expense_details
    grand_total_cents = all_details.sum { |d| d.amount_cents.to_i }

    items_per_page = 25
    chunks = all_details.each_slice(items_per_page).to_a
    total_pages = chunks.size

    chunks.each_with_index do |chunk, page_index|
      page = doc.pages.add([ 0, 0, 612, 792 ])
      canvas = page.canvas

      canvas.font("Helvetica", size: 14)
      canvas.text("Schedule E (Form 1040) — Supplemental Statement", at: [ 54, 720 ])

      canvas.font("Helvetica", size: 9)
      canvas.text("Page #{page_index + 1} of #{total_pages}", at: [ 490, 720 ])

      canvas.font("Helvetica", size: 10)
      canvas.text("Tax Year: #{@year}", at: [ 54, 700 ])
      canvas.text("Property: #{@property.address}", at: [ 54, 685 ])
      canvas.text("Line 19 — Other Expenses Detail", at: [ 54, 665 ])

      canvas.stroke_color(180, 180, 180)
      canvas.line(54, 655, 558, 655).stroke

      # Column headers
      canvas.font("Helvetica", variant: :bold, size: 9)
      canvas.text("Date", at: [ 54, 642 ])
      canvas.text("Description", at: [ 140, 642 ])
      canvas.text("Amount", at: [ 490, 642 ])
      canvas.line(54, 634, 558, 634).stroke

      y = 618
      chunk.each do |detail|
        amount_cents = detail.amount_cents.to_i
        date_str = detail.occurred_on.strftime("%b %-d, %Y")
        desc_str = detail.description.to_s.truncate(60)
        amt_str = "$%.2f" % (amount_cents / 100.0)

        canvas.font("Helvetica", size: 9)
        canvas.text(date_str, at: [ 54, y ])
        canvas.text(desc_str, at: [ 140, y ])
        canvas.text(amt_str, at: [ 490, y ])
        y -= 18
      end

      canvas.line(54, y + 4, 558, y + 4).stroke
      y -= 14

      if page_index == total_pages - 1
        total_str = "$%.2f" % (grand_total_cents / 100.0)
        canvas.font("Helvetica", variant: :bold, size: 9)
        canvas.text("Total Line 19 Other Expenses (rounded to Line 19 on form):", at: [ 140, y ])
        canvas.text(total_str, at: [ 490, y ])
      else
        canvas.font("Helvetica", variant: :italic, size: 9)
        canvas.text("(Continued on next page...)", at: [ 140, y ])
      end
    end
  end

  def fill_totals(form)
    # Portfolio summary totals (Lines 23a–26) remain blank on single-property worksheet.
  end

  def set_field(form, key, value)
    field_name = field_map[key]
    return unless field_name

    field = form.field_by_name(field_name)
    return unless field

    field.field_value = value.to_s
  rescue HexaPDF::Error => e
    Rails.logger.warn("ScheduleEGenerator: Could not set #{key} (#{field_name}): #{e.message}")
  end

  def field_map
    @field_map ||= case @year
    when 2023..Float::INFINITY then MAP_2023_PRESENT
    when 2022                  then MAP_2022
    when 2019..2021            then MAP_2019_2021
    when 2016..2018            then MAP_2016_2018
    when 2014..2015            then MAP_2014_2015
    when 2013                  then MAP_2013
    when 2012                  then MAP_2012
    when 2011                  then MAP_2011
    else MAP_2023_PRESENT
    end
  end

  def template_path
    path = Rails.root.join("app/assets/pdfs/f1040se--#{@year}.pdf")
    return path if File.exist?(path)

    raise TemplateMissingError, "No Schedule E PDF template found for year #{@year}"
  end

  def format_amount(amount)
    BigDecimal(amount.to_s).round(0, BigDecimal::ROUND_HALF_UP).to_i.to_s
  end

  # --- Data queries ---

  def schedule_e_result
    @schedule_e_result ||= TaxReporting::ScheduleEQuery.call(property: @property, tax_year: @year)
  end

  def rents_received
    schedule_e_result.rents_received
  end

  def expenses_by_category
    @expenses_by_category ||= schedule_e_result.expenses_by_category_cents.transform_keys(&:to_s).transform_values do |cents|
      BigDecimal(cents.to_s) / 100
    end
  end

  def total_expenses
    schedule_e_result.total_expenses
  end

  def net_income
    schedule_e_result.net_income
  end
end
