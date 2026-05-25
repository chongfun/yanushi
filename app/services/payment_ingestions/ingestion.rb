# app/services/payment_ingestions/ingestion.rb
module PaymentIngestions
  class Ingestion
    PARSERS = {
      "zelle" => Parsers::Zelle,
      "venmo" => Parsers::Venmo
    }.freeze

    def call(user:, pdf_path_or_io:, source: "pdf_upload")
      # Extract text and run parsing in the user's local timezone context
      Time.use_zone(user.timezone) do
        require "stringio"
        require "hexapdf"

        pdf_bytes, filename, page_count, raw_text, payment_document = extract_pdf_data(pdf_path_or_io, user)

        receipt_type = detect_type(raw_text)

        if receipt_type == "unknown"
          raise PaymentIngestions::ParsingError, "Unrecognized document format"
        end

        if receipt_type != "chase_statement" && page_count > 1
          raise PaymentIngestions::ParsingError, "Multi-page statement PDFs are not supported"
        end

        # Parse results
        parser_results = if receipt_type == "chase_statement"
          Parsers::ChaseStatement.new.parse(raw_text)
        else
          parser = PARSERS[receipt_type].new
          [ parser.parse(raw_text) ]
        end

        ingestions = build_ingestions(
          user: user,
          source: source,
          receipt_type: receipt_type,
          parser_results: parser_results,
          raw_text: raw_text,
          payment_document: payment_document
        )

        # Raise error if no matching tenant transactions found in Chase statement
        if receipt_type == "chase_statement" && ingestions.empty?
          raise PaymentIngestions::ParsingError, "No matching tenant transactions found"
        end

        # Save payment_document if we have at least one ingestion, or if it was a single receipt (even if failed)
        if ingestions.any? || receipt_type != "chase_statement"
          payment_document.save! if payment_document.new_record?
          ingestions.each(&:save!)
        end

        # Return array of saved ingestions if it's a statement, otherwise return the single ingestion record
        if receipt_type == "chase_statement"
          ingestions
        else
          ingestions.first || PaymentIngestion.new(
            user: user,
            source: source,
            receipt_type: receipt_type,
            status: :failed,
            raw_text: raw_text,
            payment_document: payment_document
          )
        end
      end
    end

    private

    def extract_pdf_data(pdf_path_or_io, user)
      if pdf_path_or_io.is_a?(PaymentDocument)
        payment_document = pdf_path_or_io
        pdf_bytes = payment_document.has_attribute?(:attachment_file) ? payment_document.attachment_file : PaymentDocument.where(id: payment_document.id).pluck(:attachment_file).first
        filename = payment_document.attachment_filename
        io = StringIO.new(pdf_bytes)
        doc = HexaPDF::Document.new(io: io)
      else
        pdf_bytes = read_pdf_bytes(pdf_path_or_io)

        doc = if pdf_path_or_io.respond_to?(:read) && pdf_path_or_io.respond_to?(:seek)
          HexaPDF::Document.new(io: pdf_path_or_io)
        elsif pdf_path_or_io.respond_to?(:path)
          HexaPDF::Document.open(pdf_path_or_io.path.to_s)
        else
          HexaPDF::Document.open(pdf_path_or_io.to_s)
        end

        filename = if pdf_path_or_io.respond_to?(:original_filename)
          pdf_path_or_io.original_filename
        elsif pdf_path_or_io.respond_to?(:path)
          File.basename(pdf_path_or_io.path)
        else
          File.basename(pdf_path_or_io.to_s)
        end
        # Fallback for string-converted IO descriptors
        filename = "receipt.pdf" if filename.blank? || filename.include?("#<")
      end

      page_count = doc.pages.count

      raw_text = doc.pages.map do |page|
        extractor = doc.task(:smart_text_extractor) rescue nil
        if extractor
          extractor.text(page)
        else
          page.extract_text rescue ""
        end
      end.join("\n")

      unless pdf_path_or_io.is_a?(PaymentDocument)
        payment_document = PaymentDocument.new(
          user: user,
          attachment_file: pdf_bytes,
          attachment_filename: filename,
          attachment_content_type: "application/pdf"
        )
      end

      [ pdf_bytes, filename, page_count, raw_text, payment_document ]
    end

    def read_pdf_bytes(pdf_path_or_io)
      if pdf_path_or_io.respond_to?(:read) && pdf_path_or_io.respond_to?(:rewind)
        pdf_path_or_io.rewind
        bytes = pdf_path_or_io.read
        pdf_path_or_io.rewind
        bytes
      elsif pdf_path_or_io.respond_to?(:path)
        File.binread(pdf_path_or_io.path)
      else
        File.binread(pdf_path_or_io.to_s)
      end
    end

    def detect_type(text)
      if text.match?(/CHASE TOTAL CHECKING/i) && text.match?(/TRANSACTION DETAIL/i)
        "chase_statement"
      elsif text.match?(/Transaction ID\s+\d+/i) || text.match?(/venmo/i)
        "venmo"
      elsif text.match?(/zelle/i) || text.match?(/Transaction number/i) || text.match?(/sent you money/i)
        "zelle"
      else
        "unknown"
      end
    end

    def build_ingestions(user:, source:, receipt_type:, parser_results:, raw_text:, payment_document:)
      ingestions = []

      parser_results.each do |result|
        if result.success?
          resolve_result = TenantResolver.new.resolve(user, result.payer_name, result.payer_username)

          # For bank statements, discard unmatched items to avoid cluttering the UI with other personal expenses/deposits
          if receipt_type == "chase_statement" && resolve_result.status.to_s == "unmatched"
            next
          end

          tenant = resolve_result.tenant
          lease = tenant&.leases&.find { |l| active_lease?(l, result.payment_date) }

          ingestions << PaymentIngestion.new(
            user: user,
            source: source,
            receipt_type: result.receipt_type,
            status: resolve_result.status,
            payer_name: result.payer_name,
            payer_username: result.payer_username,
            amount: result.amount,
            payment_date: result.payment_date,
            payment_method: result.payment_method,
            transaction_number: result.transaction_number,
            raw_text: result.raw_text,
            tenant: tenant,
            lease: lease,
            payment_document: payment_document
          )
        else
          # For receipts, if parsing failed, we still keep it. For statements, we don't save failed results
          unless receipt_type == "chase_statement"
            ingestions << PaymentIngestion.new(
              user: user,
              source: source,
              receipt_type: receipt_type,
              status: :failed,
              raw_text: raw_text,
              error_message: result.error_message,
              payment_document: payment_document
            )
          end
        end
      end

      ingestions
    end

    def active_lease?(lease, payment_date)
      return true if lease.month_to_month?
      return true unless lease.termination_date
      date = payment_date || Date.current
      date >= lease.commencement_date && date <= lease.termination_date
    end
  end
end
