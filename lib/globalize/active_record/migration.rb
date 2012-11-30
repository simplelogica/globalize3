require 'digest/sha1'

module Globalize
  module ActiveRecord
    module Migration
      attr_reader :globalize_migrator

      def globalize_migrator
        @globalize_migrator ||= Migrator.new(self)
      end

      delegate :create_translation_table!, :add_translation_fields!, :drop_translation_table!, :remove_translation_fields!, :translation_index_name, :translation_locale_index_name,
        :to => :globalize_migrator

      class Migrator
        include Globalize::ActiveRecord::Exceptions

        attr_reader :model, :fields
        delegate :translated_attribute_names, :connection, :table_name,
          :table_name_prefix, :translations_table_name, :columns, :to => :model

        def initialize(model)
          @model = model
        end

        def create_translation_table!(fields = {}, options = {})
          @fields = fields
          # If we have fields we only want to create the translation table with those fields
          complete_translated_fields if fields.blank?
          validate_translated_fields

          create_translation_table
          add_translation_fields!(fields, options)
          create_translations_index
          clear_schema_cache!
        end

        def add_translation_fields!(fields, options = {})
          @fields = fields
          validate_translated_fields

          add_translation_fields
          clear_schema_cache!
          move_data_to_translation_table if options[:migrate_data]
          remove_source_columns if options[:remove_source_columns]
          clear_schema_cache!
        end

        def remove_translation_fields!(fields, options = {})
          @fields = fields
          validate_translated_fields

          if options[:migrate_data]
            move_data_to_model_table
          else
            add_missing_columns
            clear_schema_cache!
          end

          remove_translation_fields
          clear_schema_cache!
        end

        def remove_source_columns
          connection.remove_columns(table_name, *fields.keys)
        end

        def drop_translation_table!(options = {})
          move_data_to_model_table if options[:migrate_data]
          drop_translations_index
          drop_translation_table
          clear_schema_cache!
        end

        # This adds all the current translated attributes of the model
        # It's a problem because in early migrations would add all the translated attributes
        def complete_translated_fields
          translated_attribute_names.each do |name|
            fields[name] = column_type(name) unless fields[name]
          end
        end

        def create_translation_table
          connection.create_table(translations_table_name) do |t|
            t.references table_name.sub(/^#{table_name_prefix}/, '').singularize
            t.string :locale
            t.timestamps
          end
        end

        def add_translation_fields
          connection.change_table(translations_table_name) do |t|
            fields.each do |name, options|
              if options.is_a? Hash
                t.column name, options.delete(:type), options
              else
                t.column name, options
              end
            end
          end
        end

        def remove_translation_fields
          connection.remove_columns(translations_table_name, *fields.keys)
        end

        def create_translations_index
          connection.add_index(
            translations_table_name,
            "#{table_name.sub(/^#{table_name_prefix}/, "").singularize}_id",
            :name => translation_index_name
          )
          # index for select('DISTINCT locale') call in translation.rb
          connection.add_index(
            translations_table_name,
            :locale,
            :name => translation_locale_index_name
          )
        end

        def drop_translation_table
          connection.drop_table(translations_table_name)
        end

        def drop_translations_index
          connection.remove_index(translations_table_name, :name => translation_index_name)
        end

        def move_data_to_translation_table
          model.find_each do |record|
            translation = record.translation_for(I18n.default_locale) || record.translations.build(:locale => I18n.default_locale)
            fields.each do |attribute_name, attribute_type|
              translation[attribute_name] = record.read_attribute(attribute_name, {:translated => false})
            end
            translation.save!
          end
        end

        def move_data_to_model_table

          add_missing_columns
          clear_schema_cache!

          model.find_each do |record|
            translation = record.translation_for(I18n.default_locale)
            unless translation.nil?
              fields.each do |attribute_name, attribute_type|
                record[attribute_name] = translation[attribute_name]
              end
            end
            record.save!
          end
        end

        def validate_translated_fields
          fields.each do |name, options|
            raise BadFieldName.new(name) unless valid_field_name?(name)
            if options.is_a? Hash
              raise BadFieldType.new(name, options[:type]) unless valid_field_type?(name, options[:type])
            else
              raise BadFieldType.new(name, options) unless valid_field_type?(name, options)
            end
          end
        end

        def column_type(name)
          columns.detect { |c| c.name == name.to_s }.try(:type)
        end

        def valid_field_name?(name)
          translated_attribute_names.include?(name)
        end

        def valid_field_type?(name, type)
          !translated_attribute_names.include?(name) || [:string, :text].include?(type)
        end

        def translation_index_name
          index_name = "index_#{translations_table_name}_on_#{table_name.singularize}_id"
          index_name.size < connection.index_name_length ? index_name : "index_#{Digest::SHA1.hexdigest(index_name)}"
        end

        def translation_locale_index_name
          index_name = "index_#{translations_table_name}_on_locale"
          index_name.size < connection.index_name_length ? index_name : "index_#{Digest::SHA1.hexdigest(index_name)}"
        end

        def clear_schema_cache!
          connection.schema_cache.clear! if connection.respond_to? :schema_cache
          model::Translation.reset_column_information
          model.reset_column_information
        end

        private

        def add_missing_columns
          fields.keys.map(&:to_s).each do |attribute|
            unless model.column_names.include?(attribute)
              connection.add_column(table_name, attribute, model::Translation.columns_hash[attribute].type)
            end
          end
        end

      end
    end
  end
end
