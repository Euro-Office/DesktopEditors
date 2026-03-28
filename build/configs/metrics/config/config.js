/*
 * (c) Copyright Ascensio System SIA 2010-2024
 *
 * This program is a free software product. You can redistribute it and/or
 * modify it under the terms of the GNU Affero General Public License (AGPL)
 * version 3 as published by the Free Software Foundation. In accordance with
 * Section 7(a) of the GNU AGPL its Section 15 shall be amended to the effect
 * that Ascensio System SIA expressly excludes the warranty of non-infringement
 * of any third-party rights.
 *
 * This program is distributed WITHOUT ANY WARRANTY; without even the implied
 * warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR  PURPOSE. For
 * details, see the GNU AGPL at: http://www.gnu.org/licenses/agpl-3.0.html
 *
 * You can contact Ascensio System SIA at 20A-6 Ernesta Birznieka-Upish
 * street, Riga, Latvia, EU, LV-1050.
 *
 * The  interactive user interfaces in modified source and object code versions
 * of the Program must display Appropriate Legal Notices, as required under
 * Section 5 of the GNU AGPL version 3.
 *
 * Pursuant to Section 7(b) of the License you must retain the original Product
 * logo when distributing the program. Pursuant to Section 7(e) we decline to
 * grant you any rights under trademark law for use of our trademarks.
 *
 * All the Product's GUI elements, including illustrations and icon sets, as
 * well as technical writing content are licensed under the terms of the
 * Creative Commons Attribution-ShareAlike 4.0 International. See the License
 * terms at http://creativecommons.org/licenses/by-sa/4.0/legalcode
 *
 */

/*

Required Variables:

  port:             StatsD listening port [default: 8125]

Graphite Required Variables:

(Leave these unset to avoid sending stats to Graphite.
 Set debug flag and leave these unset to run in 'dry' debug mode -
 useful for testing statsd clients without a Graphite server.)

  graphiteHost:     hostname or IP of Graphite server
  graphitePort:     port of Graphite server

Optional Variables:

  backends:         an array of backends to load. Each backend must exist
                    by name in the directory backends/. If not specified,
                    the default graphite backend will be loaded.
  debug:            debug flag [default: false]
  address:          address to listen on over UDP [default: 0.0.0.0]
  address_ipv6:     defines if the address is an IPv4 or IPv6 address [true or false, default: false]
  port:             port to listen for messages on over UDP [default: 8125]
  mgmt_address:     address to run the management TCP interface on
                    [default: 0.0.0.0]
  mgmt_port:        port to run the management TCP interface on [default: 8126]
  title :           Allows for overriding the process title. [default: statsd]
                    if set to false, will not override the process title and let the OS set it.
                    The length of the title has to be less than or equal to the binary name + cli arguments
                    NOTE: This does not work on Mac's with node versions prior to v0.10

  healthStatus:     default health status to be returned and statsd process starts ['up' or 'down', default: 'up']
  dumpMessages:     log all incoming messages
  flushInterval:    interval (in ms) to flush to Graphite
  percentThreshold: for time information, calculate the Nth percentile(s)
                    (can be a single value or list of floating-point values)
                    negative values mean to use "top" Nth percentile(s) values
                    [%, default: 90]
  flush_counts:     send stats_counts metrics [default: true]

  keyFlush:         log the most frequently sent keys [object, default: undefined]
    interval:       how often to log frequent keys [ms, default: 0]
    percent:        percentage of frequent keys to log [%, default: 100]
    log:            location of log file for frequent keys [default: STDOUT]
  deleteIdleStats:  don't send values to graphite for inactive counters, sets, gauges, or timeers
                    as opposed to sending 0.  For gauges, this unsets the gauge (instead of sending
                    the previous value). Can be individually overriden. [default: false]
  deleteGauges  :   don't send values to graphite for inactive gauges, as opposed to sending the previous value [default: false]
  deleteTimers:     don't send values to graphite for inactive timers, as opposed to sending 0 [default: false]
  deleteSets:       don't send values to graphite for inactive sets, as opposed to sending 0 [default: false]
  deleteCounters:   don't send values to graphite for inactive counters, as opposed to sending 0 [default: false]
  prefixStats:      prefix to use for the statsd statistics data for this running instance of statsd [default: statsd]
                    applies to both legacy and new namespacing

  console:
    prettyprint:    whether to prettyprint the console backend
                    output [true or false, default: true]

  log:              log settings [object, default: undefined]
    backend:        where to log: stdout or syslog [string, default: stdout]
    application:    name of the application for syslog [string, default: statsd]
    level:          log level for [node-]syslog [string, default: LOG_INFO]

  graphite:
    legacyNamespace:  use the legacy namespace [default: true]
    globalPrefix:     global prefix to use for sending stats to graphite [default: "stats"]
    prefixCounter:    graphite prefix for counter metrics [default: "counters"]
    prefixTimer:      graphite prefix for timer metrics [default: "timers"]
    prefixGauge:      graphite prefix for gauge metrics [default: "gauges"]
    prefixSet:        graphite prefix for set metrics [default: "sets"]
    globalSuffix:     global suffix to use for sending stats to graphite [default: ""]
                      This is particularly useful for sending per host stats by
                      settings this value to: require('os').hostname().split('.')[0]

  repeater:         an array of hashes of the for host: and port:
                    that details other statsd servers to which the received
                    packets should be "repeated" (duplicated to).
                    e.g. [ { host: '10.10.10.10', port: 8125 },
                           { host: 'observer', port: 88125 } ]

  repeaterProtocol: whether to use udp4 or udp6 for repeaters.
                    ["udp4" or "udp6", default: "udp4"]

  histogram:        for timers, an array of mappings of strings (to match metrics) and
                    corresponding ordered non-inclusive upper limits of bins.
                    For all matching metrics, histograms are maintained over
                    time by writing the frequencies for all bins.
                    'inf' means infinity. A lower limit of 0 is assumed.
                    default: [], meaning no histograms for any timer.
                    First match wins.  examples:
                    * histogram to only track render durations, with unequal
                      class intervals and catchall for outliers:
                      [ { metric: 'render', bins: [ 0.01, 0.1, 1, 10, 'inf'] } ]
                    * histogram for all timers except 'foo' related,
                      equal class interval and catchall for outliers:
                     [ { metric: 'foo', bins: [] },
                       { metric: '', bins: [ 50, 100, 150, 200, 'inf'] } ]

*/
{
  port: 8125
, flushInterval: 600000
, backends: [ "./backends/console" ]
}
