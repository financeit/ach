require 'date'

module ACH
  class ACHFile
    include FieldIdentifiers

    attr_reader :batches
    attr_reader :header
    attr_reader :control

    def initialize data=nil
      @batches = []
      @header = Records::FileHeader.new
      @control = Records::FileControl.new

      if data
        parse(data)
      end
    end

    def to_s
      records = []
      records << @header

      batch_number = 0
      @batches.each { |b| records += b.to_ach(batch_number+=1) }

      records << @control

      nines_needed = 10 - (records.length % 10)
      nines_needed = nines_needed % 10
      nines_needed.times { records << Records::Nines.new() }

      @control.batch_count  = @batches.length
      @control.block_count  = (records.length / 10).ceil
      @control.entry_count  = 0
      @control.debit_total  = 0
      @control.credit_total = 0
      @control.entry_hash   = 0

      @batches.each do | batch |
        @control.entry_count  += batch.entries.length
        @control.debit_total  += batch.control.debit_total
        @control.credit_total += batch.control.credit_total
        @control.entry_hash   += batch.control.entry_hash
      end

      records.collect { |r| r.to_ach }.join("\r\n") + "\r\n"
    end

    def report
      to_s # To ensure correct records
      lines = []

      @batches.each do | batch |
        batch.entries.each do | entry |
          lines << left_justify(entry.individual_name + ": ", 25) +
              sprintf("% 7d.%02d", entry.amount / 100, entry.amount % 100)
        end
      end
      lines << ""
      lines << left_justify("Debit Total: ", 25) +
          sprintf("% 7d.%02d", @control.debit_total / 100, @control.debit_total % 100)
      lines << left_justify("Credit Total: ", 25) +
          sprintf("% 7d.%02d", @control.credit_total / 100, @control.credit_total % 100)

      lines.join("\r\n")
    end

    def parse data
      trace_number = 0
      fh =  self.header
      batch = nil
      bh = nil
      ed = nil

      data.strip.split(/\n|\r\n/).each do |line|
        type = line[0].chr
        case type
        when '1'
          fh.immediate_destination          = line[03..12].strip
          fh.immediate_origin               = line[13..22].strip
          fh.transmission_datetime          = Time.utc('20'+line[23..24], line[25..26], line[27..28], line[29..30], line[31..32])
          fh.file_id_modifier               = line[33..33]
          fh.immediate_destination_name     = line[40..62].strip
          fh.immediate_origin_name          = line[63..85].strip
          fh.reference_code                 = line[86..93].strip
        when '5'
          self.batches << batch unless batch.nil?
          batch = ACH::Batch.new
          bh = batch.header
          bh.company_name                   = line[4..19].strip
          bh.company_identification         = line[40..49].strip
          bh.standard_entry_class_code      = line[50..52].strip
          bh.company_entry_description      = line[53..62].strip
          bh.company_descriptive_date       = Date.parse(line[63..68]) rescue nil # this can be various formats
          bh.effective_entry_date           = Date.parse(line[69..74])
          bh.originating_dfi_identification = line[79..86].strip
        when '6'
          ed = ACH::CtxEntryDetail.new
          ed.transaction_code               = line[1..2]
          ed.routing_number                 = line[3..10]
          ed.account_number                 = line[12..28].strip
          ed.amount                         = line[29..38].to_i # cents
          ed.individual_id_number           = line[39..53].strip
          ed.individual_name                = line[54..75].strip
          ed.trace_number                   = line[79..93].to_i
          batch.entries << ed
        when '7'
          type_code = line[1..2]
          ad = case type_code
          when '98'
            ACH::Addendum::NotificationOfChange.new
          when '99'
            ACH::Addendum::Return.new
          else
            ACH::Addendum.new
          end
          ad.type_code                      = type_code
          ad.payment_data                   = line[3..78].strip
          ad.sequence_number                = line[79..86].strip.to_i
          ad.entry_detail_sequence_number   = line[87..93].to_i
          ed.addenda << ad
        when '8'
          # skip
        when '9'
          # skip
        else
          raise "Didn't recognize type code #{type} for this line:\n#{line}"
        end
      end

      self.batches << batch unless batch.nil?
      batch.entries.each{ |entry| entry.trace_number = (trace_number += 1) }
      to_s
    end
  end
end
