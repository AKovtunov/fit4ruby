#!/usr/bin/env ruby -w
# encoding: UTF-8
#
# = Activity.rb -- Fit4Ruby - FIT file processing library for Ruby
#
# Copyright (c) 2014 by Chris Schlaeger <cs@taskjuggler.org>
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of version 2 of the GNU General Public License as
# published by the Free Software Foundation.
#

require 'fit4ruby/FitDataRecord'
require 'fit4ruby/FileId'
require 'fit4ruby/FileCreator'
require 'fit4ruby/DeviceInfo'
require 'fit4ruby/UserProfile'
require 'fit4ruby/Session'
require 'fit4ruby/Lap'
require 'fit4ruby/Record'
require 'fit4ruby/Event'
require 'fit4ruby/PersonalRecords'

module Fit4Ruby

  # This is the most important class of this library. It holds references to
  # all other data structures. Each of the objects it references are direct
  # equivalents of the message record structures used in the FIT file.
  class Activity < FitDataRecord

    attr_accessor :file_id, :file_creator, :device_infos, :user_profiles,
                  :sessions, :laps, :records, :events, :personal_records

    # Create a new Activity object.
    # @param field_values [Hash] A Hash that provides initial values for
    #        certain fields of the FitDataRecord.
    def initialize(field_values = {})
      super('activity')
      @meta_field_units['total_gps_distance'] = 'm'
      @num_sessions = 0

      @file_id = FileId.new
      @file_creator = FileCreator.new
      @device_infos = []
      @user_profiles = []
      @events = []
      @sessions = []
      @laps = []
      @records = []
      @personal_records = []

      @cur_session_laps = []
      @cur_lap_records = []

      @lap_counter = 1

      set_field_values(field_values)
    end

    # Perform some basic logical checks on the object and all references sub
    # objects. Any errors will be reported via the Log object.
    def check
      unless @timestamp && @timestamp >= Time.parse('1990-01-01T00:00:00+00:00')
        Log.error "Activity has no valid timestamp"
      end
      unless @total_timer_time
        Log.error "Activity has no valid total_timer_time"
      end
      unless @num_sessions == @sessions.count
        Log.error "Activity record requires #{@num_sessions}, but "
                  "#{@sessions.length} session records were found in the "
                  "FIT file."
      end
      @sessions.each { |s| s.check(self) }
      # Laps must have a consecutively growing message index.
      @laps.each.with_index do |lap, index|
        unless lap.message_index == index
          Log.error "Lap #{index} has wrong message_index #{lap.message_index}"
        end
      end
    end

    # Convenience method that aggregates all the distances from the included
    # sessions.
    def total_distance
      d = 0.0
      @sessions.each { |s| d += s.total_distance }
      d
    end

    # Total distance convered by this activity purely computed by the GPS
    # coordinates. This may differ from the distance computed by the device as
    # it can be based on a purely calibrated footpod.
    def total_gps_distance
      timer_stops = []
      # Generate a list of all timestamps where the timer was stopped.
      @events.each do |e|
        if e.event == 'timer' && e.event_type == 'stop_all'
          timer_stops << e.timestamp
        end
      end

      # The first record of a FIT file can already have a distance associated
      # with it. The GPS location of the first record is not where the start
      # button was pressed. This introduces a slight inaccurcy when computing
      # the total distance purely on the GPS coordinates found in the records.
      d = 0.0
      last_lat = last_long = nil

      # Iterate over all the records and accumlate the distances between the
      # neiboring coordinates.
      @records.each do |r|
        if (lat = r.position_lat) && (long = r.position_long)
          if last_lat && last_long
            d += Fit4Ruby::GeoMath.distance(last_lat, last_long,
                                            lat, long)
          end
          if timer_stops[0] == r.timestamp
            # If a stop event was found for this record timestamp we clear the
            # last_* values so that the distance covered while being stopped
            # is not added to the total.
            last_lat = last_long = nil
            timer_stops.shift
          else
            last_lat = lat
            last_long = long
          end
        end
      end
      d
    end

    # Call this method to update the aggregated data fields stored in Lap and
    # Session objects.
    def aggregate
      @laps.each { |l| l.aggregate }
      @sessions.each { |s| s.aggregate }
    end

    # Convenience method that averages the speed over all sessions.
    def avg_speed
      speed = 0.0
      @sessions.each { |s| speed += s.avg_speed }
      speed / @sessions.length
    end

    # Return the heart rate when the activity recording was last stopped.
    def ending_hr
      @records.empty? ? nil : @records[-1].heart_rate
    end

    # Return the measured recovery heart rate.
    def recovery_hr
      @events.each do |e|
        return e.recovery_hr if e.event == 'recovery_hr'
      end

      nil
    end

    # Returns the predicted recovery time needed after this activity.
    # @return recovery time in seconds.
    def recovery_time
      @events.each do |e|
        return e.recovery_time if e.event == 'recovery_time'
      end

      nil
    end

    # Returns the computed VO2max value. This value is computed by the device
    # based on multiple previous activities.
    def vo2max
      @events.each do |e|
        return e.vo2max if e.event == 'vo2max'
      end

      nil
    end

    # Returns the sport type of this activity.
    def sport
      @sessions[0].sport
    end

    # Returns the sport subtype of this activity.
    def sub_sport
      @sessions[0].sub_sport
    end

    # Write the Activity data to a file.
    # @param io [IO] File reference
    # @param id_mapper [FitMessageIdMapper] Maps global FIT record types to
    #        local ones.
    def write(io, id_mapper)
      @file_id.write(io, id_mapper)
      @file_creator.write(io, id_mapper)

      (@device_infos + @user_profiles + @events + @sessions + @laps +
       @records + @personal_records).sort.each do |s|
        s.write(io, id_mapper)
      end
      super
    end

    # Add a new FileId to the Activity. It will replace any previously added
    # FileId object.
    # @param field_values [Hash] A Hash that provides initial values for
    #        certain fields of the FitDataRecord.
    # @return [FileId]
    def new_file_id(field_values = {})
      new_fit_data_record('file_id', field_values)
    end

    # Add a new FileCreator to the Activity. It will replace any previously
    # added FileCreator object.
    # @param field_values [Hash] A Hash that provides initial values for
    #        certain fields of the FitDataRecord.
    # @return [FileCreator]
    def new_file_creator(field_values = {})
      new_fit_data_record('file_creator', field_values)
    end

    # Add a new DeviceInfo to the Activity.
    # @param field_values [Hash] A Hash that provides initial values for
    #        certain fields of the FitDataRecord.
    # @return [DeviceInfo]
    def new_device_info(field_values = {})
      new_fit_data_record('device_info', field_values)
    end

    # Add a new UserProfile to the Activity.
    # @param field_values [Hash] A Hash that provides initial values for
    #        certain fields of the FitDataRecord.
    # @return [UserProfile]
    def new_user_profile(field_values = {})
      new_fit_data_record('user_profile', field_values)
    end

    # Add a new Event to the Activity.
    # @param field_values [Hash] A Hash that provides initial values for
    #        certain fields of the FitDataRecord.
    # @return [Event]
    def new_event(field_values = {})
      new_fit_data_record('event', field_values)
    end

    # Add a new Session to the Activity. All previously added Lap objects are
    # associated with this Session unless they have been associated with
    # another Session before. If there are any Record objects that have not
    # yet been associated with a Lap, a new lap will be created and the
    # Record objects will be associated with this Lap. The Lap will be
    # associated with the newly created Session.
    # @param field_values [Hash] A Hash that provides initial values for
    #        certain fields of the FitDataRecord.
    # @return [Session]
    def new_session(field_values = {})
      new_fit_data_record('session', field_values)
    end

    # Add a new Lap to the Activity. All previoulsy added Record objects are
    # associated with this Lap unless they have been associated with another
    # Lap before.
    # @param field_values [Hash] A Hash that provides initial values for
    #        certain fields of the FitDataRecord.
    # @return [Lap]
    def new_lap(field_values = {})
      new_fit_data_record('lap', field_values)
    end

    # Add a new PersonalRecord to the Activity.
    # @param field_values [Hash] A Hash that provides initial values for
    #        certain fields of the FitDataRecord.
    # @return [PersonalRecord]
    def new_personal_record(field_values = {})
      new_fit_data_record('personal_record', field_values)
    end

    # Add a new Record to the Activity.
    # @param field_values [Hash] A Hash that provides initial values for
    #        certain fields of the FitDataRecord.
    # @return [Record]
    def new_record(field_values = {})
      new_fit_data_record('record', field_values)
    end

    # Check if the current Activity is equal to the passed Activity.
    # @param a [Activity] Activity to compare this Activity with.
    # @return [TrueClass/FalseClass] true if both Activities are equal,
    # otherwise false.
    def ==(a)
      super(a) && @file_id == a.file_id &&
        @file_creator == a.file_creator &&
        @device_infos == a.device_infos && @user_profiles == a.user_profiles &&
        @events == a.events &&
        @sessions == a.sessions && personal_records == a.personal_records
    end

    # Create a new FitDataRecord.
    # @param record_type [String] Type that identifies the FitDataRecord
    #        derived class to create.
    # @param field_values [Hash] A Hash that provides initial values for
    #        certain fields of the FitDataRecord.
    # @return FitDataRecord
    def new_fit_data_record(record_type, field_values = {})
      case record_type
      when 'file_id'
        @file_id = (record = FileId.new(field_values))
      when 'file_creator'
        @file_creator = (record = FileCreator.new(field_values))
      when 'device_info'
        @device_infos << (record = DeviceInfo.new(field_values))
      when 'user_profile'
        @user_profiles << (record = UserProfile.new(field_values))
      when 'event'
        @events << (record = Event.new(field_values))
      when 'session'
        unless @cur_lap_records.empty?
          # Ensure that all previous records have been assigned to a lap.
          record = create_new_lap(field_values)
        end
        @num_sessions += 1
        @sessions << (record = Session.new(@cur_session_laps, @lap_counter,
                                           field_values))
        @cur_session_laps = []
      when 'lap'
        record = create_new_lap(field_values)
      when 'record'
        @cur_lap_records << (record = Record.new(field_values))
        @records << record
      when 'personal_records'
        @personal_records << (record = PersonalRecords.new(field_values))
      else
        record = nil
      end

      record
    end

    private

    def create_new_lap(field_values)
      lap = Lap.new(@cur_lap_records, @laps.last, field_values)
      @lap_counter += 1
      @cur_session_laps << lap
      @laps << lap
      @cur_lap_records = []

      lap
    end

  end

end

