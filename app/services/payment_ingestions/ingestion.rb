# app/services/payment_receipts/ingestion.rb
module PaymentIngestions
  class Ingestion
    PARSERS = {
      "zelle" => Parsers::Zelle,
      "venmo" => Parsers::Venmo
    }.freeze

    def call(user:, pdf_path_or_io:, source: "pdf_upload")
      # Extract text and run parsing in the user's local timezone context
      Time.use_zone(user.timezone) do
        pdf_bytes = read_pdf_bytes(pdf_path_or_io)

        require "hexapdf"
        doc = if pdf_path_or_io.respond_to?(:read) && pdf_path_or_io.respond_to?(:seek)
          HexaPDF::Document.new(io: pdf_path_or_io)
        elsif pdf_path_or_io.respond_to?(:path)
          HexaPDF::Document.open(pdf_path_or_io.path.to_s)
        else
          HexaPDF::Document.open(pdf_path_or_io.to_s)
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

        receipt_type = detect_type(raw_text)

        if receipt_type != "chase_statement" && page_count > 1
          raise PaymentIngestions::ParsingError, "Multi-page statement PDFs are not supported"
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

        # Parse results
        parser_results = if receipt_type == "chase_statement"
          Parsers::ChaseStatement.new.parse(raw_text)
        else
          parser = (PARSERS[receipt_type] || Parsers::Zelle).new
          [ parser.parse(raw_text) ]
        end

        payment_document = PaymentDocument.new(
          user: user,
          attachment_file: pdf_bytes,
          attachment_filename: filename,
          attachment_content_type: "application/pdf"
        )

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
            # For receipts, if parsing fails, we still keep it. For statements, we don't save failed results
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

        # Save payment_document if we have at least one ingestion, or if it was a single receipt (even if failed)
        if ingestions.any? || receipt_type != "chase_statement"
          payment_document.save!
          ingestions.each do |ingestion|
            ingestion.save
          end
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
      elsif text.match?(/zelle/i) || text.match?(/chase/i) || text.match?(/Transaction number/i)
        "zelle"
      else
        "unknown"
      end
    end

    def active_lease?(lease, payment_date)
      return true if lease.month_to_month?
      return true unless lease.termination_date
      date = payment_date || Date.current
      date >= lease.commencement_date && date <= lease.termination_date
    end
  end
end
