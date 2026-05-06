namespace :schedule_e do
  desc "Dump all AcroForm field names from a Schedule E PDF template"
  task :dump_fields, [ :year ] => :environment do |t, args|
    require "hexapdf"
    year = args[:year] || Time.current.year
    pdf_path = Rails.root.join("app/assets/pdfs/f1040se--#{year}.pdf")

    unless File.exist?(pdf_path)
      # Fallback to generic if it exists, though it's recommended to use year-specific
      pdf_path = Rails.root.join("app/assets/pdfs/f1040se.pdf")
    end

    unless File.exist?(pdf_path)
      puts "ERROR: PDF template not found for year #{year}."
      puts "Ensure you have app/assets/pdfs/f1040se--#{year}.pdf"
      exit 1
    end

    doc = HexaPDF::Document.open(pdf_path)

    unless doc.acro_form
      puts "ERROR: No AcroForm found in the PDF. This file may use XFA format."
      exit 1
    end

    puts "Schedule E PDF Form Fields (#{pdf_path.basename})"
    puts "=" * 80
    doc.acro_form.each_field do |field|
      puts "#{field.full_field_name}"
      puts "  Type:  #{field.field_type}"
      puts "  Value: #{field.field_value.inspect}"
      puts ""
    end
  end
end
