module Fastlane
  module Actions
    require 'fastlane_core/ui/errors/fastlane_common_error'
    require 'fastlane/actions/scan'
    require 'shellwords'
    require 'xctest_list'
    require 'plist'

    class MultiScanAction < Action
      def self.run(params)
        params[:quit_simulators] = params._values[:force_quit_simulator] if params._values[:force_quit_simulator]

        print_multi_scan_parameters(params)
        force_quit_simulator_processes if params[:quit_simulators]

        prepare_for_testing(params.values)
        
        platform = :mac
        platform = :ios_simulator if Scan.config[:destination].any? { |d| d.include?('platform=iOS Simulator') }

        runner_options = params.values.merge(platform: platform)
        runner = ::TestCenter::Helper::MultiScanManager::Runner.new(runner_options)
        tests_passed = runner.run

        summary = run_summary(params, tests_passed)
        print_run_summary(summary)
        
        if params[:fail_build] && !tests_passed
          raise UI.test_failure!('Tests have failed')
        end
        summary
      end

      def self.print_multi_scan_parameters(params)
        return if Helper.test?
        # :nocov:
        scan_keys = Fastlane::Actions::ScanAction.available_options.map(&:key)
        FastlaneCore::PrintTable.print_values(
          config: params._values.reject { |k, _| scan_keys.include?(k) },
          title: "Summary for multi_scan (test_center v#{Fastlane::TestCenter::VERSION})"
        )
        # :nocov:
      end

      def self.print_run_summary(summary)        
        return if Helper.test?

        # :nocov:
        FastlaneCore::PrintTable.print_values(
          config: summary,
          title: "multi_scan results"
        )
        # :nocov:
      end

      def self.run_summary(scan_options, tests_passed)
        reportnamer = ::TestCenter::Helper::ReportNameHelper.new(
          scan_options[:output_types],
          scan_options[:output_files],
          scan_options[:custom_report_file_name]
        )
        passing_testcount = 0
        failed_tests = []
        failure_details = {}
        report_files = Dir.glob("#{scan_options[:output_directory]}/**/#{reportnamer.junit_fileglob}").map do |relative_filepath|
          File.absolute_path(relative_filepath)
        end
        retry_total_count = 0
        report_files.each do |report_file|
          junit_results = other_action.tests_from_junit(junit: report_file)
          failed_tests.concat(junit_results[:failed])
          passing_testcount += junit_results[:passing].size
          failure_details.merge!(junit_results[:failure_details])

          report = REXML::Document.new(File.new(report_file))
          retry_total_count += (report.root.attribute('retries')&.value || 1).to_i
        end

        if reportnamer.includes_html?
          report_files += Dir.glob("#{scan_options[:output_directory]}/**/#{reportnamer.html_fileglob}").map do |relative_filepath|
            File.absolute_path(relative_filepath)
          end
        end
        if reportnamer.includes_json?
          report_files += Dir.glob("#{scan_options[:output_directory]}/**/#{reportnamer.json_fileglob}").map do |relative_filepath|
            File.absolute_path(relative_filepath)
          end
        end
        if scan_options[:result_bundle]
          report_files += Dir.glob("#{scan_options[:output_directory]}/**/*.test_result").map do |relative_test_result_bundle_filepath|
            File.absolute_path(relative_test_result_bundle_filepath)
          end
        end
        {
          result: tests_passed,
          total_tests: passing_testcount + failed_tests.size,
          passing_testcount: passing_testcount,
          failed_testcount: failed_tests.size,
          failed_tests: failed_tests,
          failure_details: failure_details,
          total_retry_count: retry_total_count,
          report_files: report_files
        }
      end

      def self.prepare_for_testing(scan_options)
        reset_scan_config_to_defaults
        use_scanfile_to_override_settings(scan_options)
        ScanHelper.remove_preexisting_simulator_logs(scan_options)
        if scan_options[:test_without_building] || scan_options[:skip_build]
          UI.verbose("Preparing Scan config options for multi_scan testing")
          prepare_scan_config(scan_options)
        else
          UI.verbose("Building the project in preparation for multi_scan testing")
          build_for_testing(scan_options)
        end
      end

      def self.reset_scan_config_to_defaults
        return unless Scan.config

        defaults = Hash[Fastlane::Actions::ScanAction.available_options.map { |i| [i.key, i.default_value] }]
        FastlaneCore::UI.verbose("MultiScanAction resetting Scan config to defaults")
        defaults.delete(:destination)

        Scan.config._values.each do |k,v|
          Scan.config.set(k, defaults[k]) if defaults.key?(k)
        end
      end

      def self.use_scanfile_to_override_settings(scan_options)
        overridden_options = ScanHelper.options_from_configuration_file(
          ScanHelper.scan_options_from_multi_scan_options(scan_options)
        )
        
        unless overridden_options.empty?
          FastlaneCore::UI.important("Scanfile found: overriding multi_scan options with it's values.")
          overridden_options.each do |k,v|
            scan_options[k] = v
          end
        end
      end

      def self.prepare_scan_config(scan_options)
        Scan.config ||= FastlaneCore::Configuration.create(
          Fastlane::Actions::ScanAction.available_options,
          ScanHelper.scan_options_from_multi_scan_options(scan_options)
        )
      end

      def self.build_for_testing(scan_options)
        values = prepare_scan_options_for_build_for_testing(scan_options)
        ScanHelper.print_scan_parameters(values)

        remove_preexisting_xctestrun_files
        Scan::Runner.new.run
        update_xctestrun_after_build(scan_options)
        remove_build_report_files

        Scan.config._values.delete(:build_for_testing)
        scan_options[:derived_data_path] = Scan.config[:derived_data_path]
      end

      def self.prepare_scan_options_for_build_for_testing(scan_options)
        Scan.config = FastlaneCore::Configuration.create(
          Fastlane::Actions::ScanAction.available_options,
          ScanHelper.scan_options_from_multi_scan_options(scan_options.merge(build_for_testing: true))
        )
        values = Scan.config.values(ask: false)
        values[:xcode_path] = File.expand_path("../..", FastlaneCore::Helper.xcode_path)
        values
      end

      def self.update_xctestrun_after_build(scan_options)
        xctestrun_files = Dir.glob("#{Scan.config[:derived_data_path]}/Build/Products/*.xctestrun")
        UI.verbose("After building, found xctestrun files #{xctestrun_files} (choosing 1st)")
        scan_options[:xctestrun] = xctestrun_files.first
      end

      def self.remove_preexisting_xctestrun_files
        xctestrun_files = Dir.glob("#{Scan.config[:derived_data_path]}/Build/Products/*.xctestrun")
        UI.verbose("Before building, removing pre-existing xctestrun files: #{xctestrun_files}")
        FileUtils.rm_rf(xctestrun_files)
      end

      def self.remove_build_report_files
        # When Scan builds, it generates empty report files. Trying to collate
        # subsequent, valid, report files with the empty report file will fail
        # because there is no shared XML elements
        report_options = Scan::XCPrettyReporterOptionsGenerator.generate_from_scan_config
        output_files = report_options.instance_variable_get(:@output_files)
        output_directory = report_options.instance_variable_get(:@output_directory)

        UI.verbose("Removing report files generated by the build")
        output_files.each do |output_file|
          report_file = File.join(output_directory, output_file)
          UI.verbose("  #{report_file}")
          FileUtils.rm_f(report_file)
        end
      end

      def self.force_quit_simulator_processes
        # Silently execute and kill, verbose flags will show this command occurring
        Fastlane::Actions.sh("killall Simulator &> /dev/null || true", log: false)
      end

      #####################################################
      # @!group Documentation
      #####################################################

      # :nocov:
      def self.description
        "Uses scan to run Xcode tests a given number of times, with the option of batching and/or parallelizing them, only re-testing failing tests."
      end

      def self.details
        "Use this action to run your tests if you have fragile tests that fail " \
        "sporadically, if you have a huge number of tests that should be " \
        "batched, or have multiple test targets and need meaningful junit reports."
      end

      def self.return_value
        "Returns a Hash with the following value-key pairs:\n" \
        "- result: true if the final result of running the tests resulted in " \
        "passed tests. false if there was one or more tests that failed, even " \
        "after retrying them :try_count times.\n" \
        "- total_tests: the total number of tests visited.\n" \
        "- passing_testcount: the number of tests that passed.\n" \
        "- failed_testcount: the number of tests that failed, even after retrying them.\n" \
        "- failed_tests: an array of the test identifers that failed.\n" \
        "- total_retry_count: the total number of times a test 'run' was retried.\n" \
        "- report_files: the list of junit report files generated by multi_scan."
      end

      def self.scan_options
        # multi_scan has its own enhanced version of `output_types` and we want to provide
        # the help and validation for that new version.
        ScanAction.available_options.reject { |config| %i[output_types].include?(config.key) }
      end

      def self.available_options
        scan_options + [
          FastlaneCore::ConfigItem.new(
            key: :try_count,
            env_name: "FL_MULTI_SCAN_TRY_COUNT",
            description: "The number of times to retry running tests via scan",
            type: Integer,
            is_string: false,
            default_value: 1
          ),
          FastlaneCore::ConfigItem.new(
            key: :batch_count,
            env_name: "FL_MULTI_SCAN_BATCH_COUNT",
            description: "The number of test batches to run through scan. Can be combined with :try_count",
            type: Integer,
            is_string: false,
            default_value: 1,
            optional: true,
            verify_block: proc do |count|
              UI.user_error!("Error: Batch counts must be greater than zero") unless count > 0
            end
          ),
          FastlaneCore::ConfigItem.new(
            key: :invocation_based_tests,
            description: "Set to true If your test suit have invocation based tests like Kiwi",
            type: Boolean,
            is_string: false,
            default_value: false,
            optional: true,
            conflicting_options: [:batch_count],
            conflict_block: proc do |value|
              UI.user_error!(
                "Error: Can't use 'invocation_based_tests' and 'batch_count' options in one run, "\
                "because the number of tests is unknown")
            end
          ),
          FastlaneCore::ConfigItem.new(
            key: :quit_simulators,
            env_name: "FL_MULTI_SCAN_QUIT_SIMULATORS",
            description: "If the simulators need to be killed before running the tests",
            type: Boolean,
            is_string: false,
            default_value: true,
            optional: true
          ),
          FastlaneCore::ConfigItem.new(
            key: :output_types,
            short_option: "-f",
            env_name: "SCAN_OUTPUT_TYPES",
            description: "Comma separated list of the output types (e.g. html, junit, json, json-compilation-database)",
            default_value: "html,junit"
          ),
          FastlaneCore::ConfigItem.new(
            key: :collate_reports,
            description: "Whether or not to collate the reports generated by multiple retries, batches, and parallel test runs",
            default_value: true,
            is_string: false
          ),
          FastlaneCore::ConfigItem.new(
            key: :parallel_testrun_count,
            description: 'Run simulators each batch of tests and/or each test target in parallel on its own Simulator',
            optional: true,
            is_string: false,
            default_value: 1,
            verify_block: proc do |count|
              UI.user_error!("Error: :parallel_testrun_count must be greater than zero") unless count > 0
              UI.important("Warning: the CoreSimulatorService may fail to connect to simulators if :parallel_testrun_count is greater than 6") if count > 6
            end
          ),
          FastlaneCore::ConfigItem.new(
            key: :testrun_completed_block,
            description: 'A block invoked each time a test run completes. When combined with :parallel_testrun_count, will be called separately in each child process',
            optional: true,
            is_string: false,
            default_value: nil,
            type: Proc
          )
        ]
      end

      def self.example_code
        [
          "
          UI.important(
            'example: ' \\
            'run tests for a scheme that has two test targets, re-trying up to 2 times if ' \\
            'tests fail. Turn off the default behavior of failing the build if, at the ' \\
            'end of the action, there were 1 or more failing tests.'
          )
          summary = multi_scan(
            project: File.absolute_path('../AtomicBoy/AtomicBoy.xcodeproj'),
            scheme: 'AtomicBoy',
            try_count: 3,
            fail_build: false,
            output_files: 'report.html',
            output_types: 'html'
          )
          UI.success(\"multi_scan passed? \#{summary[:result]}\")
          ",
          "
          UI.important(
            'example: ' \\
            'split the tests into 2 batches and run each batch of tests up to 3 ' \\
            'times if tests fail. Do not fail the build.'
          )
          multi_scan(
            project: File.absolute_path('../AtomicBoy/AtomicBoy.xcodeproj'),
            scheme: 'AtomicBoy',
            try_count: 3,
            batch_count: 2,
            fail_build: false
          )
          ",
          "
          UI.important(
            'example: ' \\
            'split the tests into 2 batches and run each batch of tests up to 3 ' \\
            'times if tests fail. Abort the testing early if there are too many ' \\
            'failing tests by passing in a :testrun_completed_block that is called ' \\
            'by :multi_scan after each run of tests.'
          )
          test_run_block = lambda do |testrun_info|
            failed_test_count = testrun_info[:failed].size
            passed_test_count = testrun_info[:passing].size
            try_attempt = testrun_info[:try_count]
            batch = testrun_info[:batch]

            # UI.abort_with_message!('You could conditionally abort')
            UI.message(\"\\\u1F60A everything is fine, let's continue try \#{try_attempt + 1} for batch \#{batch}\")
          end

          multi_scan(
            project: File.absolute_path('../AtomicBoy/AtomicBoy.xcodeproj'),
            scheme: 'AtomicBoy',
            try_count: 3,
            batch_count: 2,
            fail_build: false,
            testrun_completed_block: test_run_block
          )
          ",
          "
          UI.important(
            'example: ' \\
            'multi_scan also works with invocation based tests.'
          )
          Dir.chdir('../AtomicBoy') do
            bundle_install
            cocoapods(podfile: File.absolute_path('Podfile'))
            multi_scan(
              workspace: File.absolute_path('AtomicBoy.xcworkspace'),
              scheme: 'KiwiBoy',
              try_count: 3,
              clean: true,
              invocation_based_tests: true,
              fail_build: false
            )
          end
          ",
          "
          UI.important(
            'example: ' \\
            'use the :workspace parameter instead of the :project parameter to find, ' \\
            'build, and test the iOS app.'
          )
          begin
            multi_scan(
              workspace: File.absolute_path('../AtomicBoy/AtomicBoy.xcworkspace'),
              scheme: 'AtomicBoy',
              try_count: 3
            )
          rescue # anything
            UI.error('Found real failing tests!')
          end
          ",
          "
          UI.important(
            'example: ' \\
            'use the :workspace parameter instead of the :project parameter to find, ' \\
            'build, and test the iOS app. Use the :skip_build parameter to not rebuild.'
          )
          multi_scan(
            workspace: File.absolute_path('../AtomicBoy/AtomicBoy.xcworkspace'),
            scheme: 'AtomicBoy',
            skip_build: true,
            clean: true,
            try_count: 3,
            result_bundle: true,
            fail_build: false
          )
          ",
          "
          UI.important(
            'example: ' \\
            'multi_scan also works with just one test target in the Scheme.'
          )
          multi_scan(
            project: File.absolute_path('../AtomicBoy/AtomicBoy.xcodeproj'),
            scheme: 'Professor',
            try_count: 3,
            output_files: 'atomic_report.xml',
            output_types: 'junit',
            fail_build: false
          )
          ",
          "
          UI.important(
            'example: ' \\
            'multi_scan also can also run just the tests passed in the ' \\
            ':only_testing option.'
          )
          multi_scan(
            workspace: File.absolute_path('../AtomicBoy/AtomicBoy.xcworkspace'),
            scheme: 'AtomicBoy',
            try_count: 3,
            code_coverage: true,
            only_testing: ['AtomicBoyTests'],
            fail_build: false
          )
          ",
          "
          UI.important(
            'example: ' \\
            'multi_scan also works with json.'
          )
          multi_scan(
            workspace: File.absolute_path('../AtomicBoy/AtomicBoy.xcworkspace'),
            scheme: 'AtomicBoy',
            try_count: 3,
            output_types: 'json',
            output_files: 'report.json',
            fail_build: false
          )
          ",
          "
          UI.important(
            'example: ' \\
            'multi_scan parallelizes its test runs.'
          )
          multi_scan(
            workspace: File.absolute_path('../AtomicBoy/AtomicBoy.xcworkspace'),
            scheme: 'AtomicBoy',
            try_count: 3,
            parallel_testrun_count: 4,
            fail_build: false
          )
          ",
          "
          UI.important(
            'example: ' \\
            'use the :xctestrun parameter instead of the :project parameter to find, ' \\
            'build, and test the iOS app.'
          )
          Dir.mktmpdir do |derived_data_path|
            project_path = File.absolute_path('../AtomicBoy/AtomicBoy.xcodeproj')
            command = \"bundle exec fastlane scan --build_for_testing true --project '\#{project_path}' --derived_data_path \#{derived_data_path} --scheme AtomicBoy\"
            `\#{command}`
            xctestrun_file = Dir.glob(\"\#{derived_data_path}/Build/Products/AtomicBoy*.xctestrun\").first
            multi_scan(
              scheme: 'AtomicBoy',
              try_count: 3,
              fail_build: false,
              xctestrun: xctestrun_file,
              test_without_building: true
            )
          end
          "
        ]
      end

      def self.authors
        ["lyndsey-ferguson/@lyndseydf"]
      end

      def self.category
        :testing
      end

      def self.is_supported?(platform)
        %i[ios mac].include?(platform)
      end
      # :nocov:
    end
  end
end
