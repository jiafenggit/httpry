#!/usr/bin/perl -w

#
#  ----------------------------------------------------
#  httpry - HTTP logging and information retrieval tool
#  ----------------------------------------------------
#
#  Copyright (c) 2005-2008 Jason Bittel <jason.bittel@gmail.com>
#

package content_analysis;

use warnings;
use Time::Local qw(timelocal);

# -----------------------------------------------------------------------------
# GLOBAL CONSTANTS
# -----------------------------------------------------------------------------
my $FLOW_TIMEOUT = 300; # In seconds

my $HOST_WEIGHT = 0.0;
my $PATH_WEIGHT = 0.5;
my $QUERY_WEIGHT = 1.0;

# -----------------------------------------------------------------------------
# GLOBAL VARIABLES
# -----------------------------------------------------------------------------
# Counter variables
my $flow_cnt = 0;
my $flow_line_cnt = 0;
my $flow_min_len = 999999;
my $flow_max_len = 0;
my $max_concurrent = 0;

# Data structures
my %active_flow = ();       # Holds metadata about each active flow
my %active_flow_data = ();  # Holds individual flow data lines
my %scored_flow = ();
my %terms = ();             # Dictionary of terms and corresponding weights

# -----------------------------------------------------------------------------
# Plugin core
# -----------------------------------------------------------------------------

&main::register_plugin(__PACKAGE__);

sub new {
        return bless {};
}

sub init {
        my $self = shift;
        my $cfg_dir = shift;

        if (&load_config($cfg_dir) == 0) {
                return 0;
        }

        &load_terms();

        # Remove any existing text files so they don't accumulate
        opendir(DIR, $output_dir) or die "Error: Cannot open directory $output_dir: $!\n";
                foreach (grep /^scored_.+\.txt$/, readdir(DIR)) {
                        unlink;
                }
        closedir(DIR);

        return 1;
}

sub main {
        my $self = shift;
        my $record = shift;
        my $curr_line;
        my $decoded_uri;

        # Retain this variable across function calls
        BEGIN {
                my $epoch_boundary = 0;

                sub get_epoch_boundary { return $epoch_boundary; }
                sub set_epoch_boundary { $epoch_boundary = shift; }
        }

        return unless (exists $record->{"direction"} && ($record->{"direction"} eq '>'));
        return unless exists $record->{"timestamp"};
        return unless exists $record->{"source-ip"};
        return unless exists $record->{"host"};
        return unless exists $record->{"request-uri"};

        $decoded_uri = $record->{"request-uri"};
        $decoded_uri =~ s/%25/%/g; # Sometimes '%' chars are double encoded
        $decoded_uri =~ s/%([a-fA-F0-9][a-fA-F0-9])/pack("C", hex($1))/eg;

        $curr_line = "$record->{'timestamp'}\t$record->{'dest-ip'}\t$record->{'host'}\t$decoded_uri";

        # Convert timestamp of current record to epoch seconds
        $record->{"timestamp"} =~ /(\d\d)\/(\d\d)\/(\d\d\d\d) (\d\d)\:(\d\d)\:(\d\d)/;
        $epochstamp = timelocal($6, $5, $4, $2, $1 - 1, $3);

        if ((keys %active_flow) > $max_concurrent) {
                $max_concurrent = keys %active_flow;
        }

        # Only call timeout_flows() if we've crossed a time boundary; i.e., 
        # if there's actually a chance for a flow to end
        if (&get_epoch_boundary() <= $epochstamp) {
                &set_epoch_boundary(&timeout_flows($epochstamp));
        }

        # Begin a new flow if one doesn't exist
        if (!exists $active_flow{$record->{"source-ip"}}) {
                $flow_cnt++;

                $active_flow{$record->{"source-ip"}}->{"length"} = 0;
                $active_flow{$record->{"source-ip"}}->{"score"} = 0;
        }

        $active_flow{$record->{"source-ip"}}->{"end_epoch"} = $epochstamp;
        $active_flow{$record->{"source-ip"}}->{"length"}++;

        push(@{ $active_flow_data{$record->{"source-ip"}} }, $curr_line);

        &content_check("$record->{'host'}$record->{'request-uri'}", $record->{"source-ip"});

        return;
}

sub end {
        &timeout_flows(0);
        &write_summary_file();

        return;
}

# -----------------------------------------------------------------------------
# Load config file and check for required options
# -----------------------------------------------------------------------------
sub load_config {
        my $cfg_dir = shift;

        # Load config file; by default in same directory as plugin
        if (-e "$cfg_dir/" . __PACKAGE__ . ".cfg") {
                require "$cfg_dir/" . __PACKAGE__ . ".cfg";
        } else {
                print "Error: No config file found\n";
                return 0;
        }

        # Check for required options and combinations
        if (!$output_file) {
                print "Error: No output file provided\n";
                return 0;
        }

        if (!$terms_file) {
                print "Error: No terms file provided\n";
                return 0;
        }

        $output_dir = "." if (!$output_dir);
        $output_dir =~ s/\/$//; # Remove trailing slash

        return 1;
}

# -----------------------------------------------------------------------------
# Read in query terms and weights from input file
# -----------------------------------------------------------------------------
sub load_terms {
        my $line;
        my $line_num;
        my $term;
        my $weight;

        open(TERMS, "$terms_file") or die "Error: Cannot open $terms_file: $!\n";
                while ($line = <TERMS>) {
                        $line_num++;
                        chomp $line;

                        $line =~ s/\#.*$//; # Remove comments
                        $line =~ s/^\s+//;  # Remove leading whitespace
                        $line =~ s/\s+$//;  # Remove trailing whitespace
                        $line =~ s/\s+/ /;  # Remove sequential whitespace
                        next if $line =~ /^$/;

                        ($term, $weight) = split / /, $line;

                        if (!$term || !$weight) {
                                print "Warning: Invalid data found in $terms_file, line $line_num\n";
                                next;
                        }

                        if ($weight < 0) {
                                print "Warning: '$term' assigned invalid weight '$weight', clamping to 0\n";
                                $weight = 0;
                        }

                        if ($weight > 1) {
                                print "Warning: '$term' assigned invalid weight '$weight', clamping to 1\n";
                                $weight = 1;
                        }

                        $terms{$term} = 1 + $weight;
                }
        close(TERMS);

        return;
}

# -----------------------------------------------------------------------------
# Search for specified terms in each line, scoring according to term and
# positional weights
# -----------------------------------------------------------------------------
sub content_check {
        my $uri = shift;
        my $ip = shift;
        my $term;

        $uri =~ /^([^\/?#]*)?([^?#]*)(\?([^#]*))?(#(.*))?/;

        my $host = $1;
        my $path = $2;
        my $query = $4;

        foreach $term (keys %terms) {
                if ($host && index($host, $term) != -1) {
                        $active_flow{$ip}->{"score"} += $HOST_WEIGHT;
                        $active_flow{$ip}->{"terms"}->{$term}++;
                }

                if ($path && index($path, $term) != -1) {
                        $active_flow{$ip}->{"score"} += $PATH_WEIGHT;
                        $active_flow{$ip}->{"terms"}->{$term}++;
                }

                if ($query && index($query, $term) != -1) {
                        $active_flow{$ip}->{"score"} += $QUERY_WEIGHT;
                        $active_flow{$ip}->{"terms"}->{$term}++;
                }
        }

        return;
}

# -----------------------------------------------------------------------------
# Handle end of flow duties: flush to disk and delete hash entries; passing an
# epochstamp value causes all flows inactive longer than $FLOW_TIMEOUT to be
# flushed, while passing a zero forces all active flows to be flushed
#
# Returns the next potential epoch value at which flows could time out
# -----------------------------------------------------------------------------
sub timeout_flows {
        my $epochstamp = shift;
        my $flow_str;
        my $epoch_diff;
        my $max_epoch_diff = 0;
        my $ip;

        foreach $ip (keys %active_flow) {
                if ($epochstamp) {
                        $epoch_diff = $epochstamp - $active_flow{$ip}->{"end_epoch"};
                        if ($epoch_diff <= $FLOW_TIMEOUT) {
                                $max_epoch_diff = $epoch_diff if ($epoch_diff > $max_epoch_diff);

                                next;
                        }
                }

                # Update flow statistics
                $flow_min_len = $active_flow{$ip}->{"length"} if ($active_flow{$ip}->{"length"} < $flow_min_len);
                $flow_max_len = $active_flow{$ip}->{"length"} if ($active_flow{$ip}->{"length"} > $flow_max_len);
                $flow_line_cnt += $active_flow{$ip}->{"length"};

                # Apply term multipliers to flow score
                map { $active_flow{$ip}->{'score'} += $active_flow{$ip}->{'terms'}->{$_} * $terms{$_} } keys %{ $active_flow{$ip}->{'terms'} };

                # Save score information only if a score has been applied
                if ($active_flow{$ip}->{'score'} > 0) {
                        $scored_flow{$ip}->{'num_flows'}++;
                        $scored_flow{$ip}->{'score'} += $active_flow{$ip}->{'score'};
                        map { $scored_flow{$ip}->{"terms"}->{$_} += $active_flow{$ip}->{"terms"}->{$_} } keys %{ $active_flow{$ip}->{"terms"} };

                        &append_scored_file($ip);
                }

                delete $active_flow{$ip};
                delete $active_flow_data{$ip};
        }

        return $epochstamp + ($FLOW_TIMEOUT - $max_epoch_diff);
}

# -----------------------------------------------------------------------------
# Append flow data to a detail file based on client IP
# -----------------------------------------------------------------------------
sub append_scored_file {
        my $ip = shift;
        my $line;

        open(HOSTFILE, ">>$output_dir/scored_$ip.txt") or die "Error: Cannot open $output_dir/scored_$ip.txt: $!\n";

        print HOSTFILE '>' x 80 . "\n";
        foreach $line (@{ $active_flow_data{$ip} }) {
                print HOSTFILE $line, "\n";
        }
        print HOSTFILE '<' x 80 . "\n";

        close(HOSTFILE);

        return;
}

# -----------------------------------------------------------------------------
# Format and write summary information to specified output file
# -----------------------------------------------------------------------------
sub write_summary_file {
        my $ip;
        my $term;
        my $term_cnt;
        my $scored_flow_cnt = 0;

        open(OUTFILE, ">$output_file") or die "Error: Cannot open $output_file: $!\n";

        print OUTFILE "\n\nCLIENT FLOWS SUMMARY\n\n";
        print OUTFILE "Generated:      " . localtime() . "\n";
        print OUTFILE "Flow count:     $flow_cnt\n";
        print OUTFILE "Flow lines:     $flow_line_cnt\n";
        print OUTFILE "Max Concurrent: $max_concurrent\n";
        print OUTFILE "Min/Max/Avg:    ";
        if ($flow_cnt > 0) {
                print OUTFILE "$flow_min_len/$flow_max_len/" . sprintf("%d", $flow_line_cnt / $flow_cnt) . "\n";
        } else {
                print OUTFILE "0/0/0\n";
        }

        if (scalar(keys %scored_flow) == 0) {
                print OUTFILE "\n\n*** No scored flows found\n";
                close(OUTFILE);

                return;
        }

        &partition_scores();

        # Delete flows and associated files from the lower partition
        foreach $ip (keys %scored_flow) {
                if ($scored_flow{$ip}->{"cluster"} == 0) {
                        delete $scored_flow{$ip};
                        unlink "$output_dir/scored_$ip.txt";
                }
        }

        map { $scored_flows_cnt += $scored_flow{$_}->{"num_flows"} } keys %scored_flow;

        print OUTFILE "\nTerms file:     $terms_file\n";
        print OUTFILE "Scored IPs:     " . (keys %scored_flow) . "\n";
        print OUTFILE "Scored flows:   $scored_flows_cnt\n\n";

        foreach $ip (sort { $scored_flow{$b}->{"score"} <=> $scored_flow{$a}->{"score"} } keys %scored_flow) {
                $term_cnt = 0;

                map { $term_cnt += $scored_flow{$ip}->{"terms"}->{$_} } keys %{ $scored_flow{$ip}->{"terms"} };

                print OUTFILE sprintf("%.1f", $scored_flow{$ip}->{"score"}) . "\t$scored_flow{$ip}->{'num_flows'}\t$ip\t$term_cnt\t";
                foreach $term (keys %{ $scored_flow{$ip}->{"terms"} } ) {
                        print OUTFILE "$term ";
                }
                print OUTFILE "\n";
        }

        close(OUTFILE);

        return;
}

# -----------------------------------------------------------------------------
# Dynamically partition scored flows into sets using the k-means clustering
# algorithm; this allows us to trim the low scoring flows off the bottom
# without setting arbitrary thresholds or levels 
#
# K-means code originally taken from: http://www.perlmonks.org/?node_id=541000
# Many subsequent modifications and changes have been made
# -----------------------------------------------------------------------------
sub partition_scores() {
        my $ip;
        my $diff;
        my $max_score = 0;
        my $new_center;
        my $pos;
        my $centroid;
        my @center = (0.0, 0.5, 1.0);
        my @members;

        # Normalize scores into the range 0..1 and flatten to two decimal places of precision
        map { $max_score = $scored_flow{$_}->{"score"} if ($scored_flow{$_}->{"score"} > $max_score) } keys %scored_flow;
        map { $scored_flow{$_}->{"norm_score"} = sprintf("%.2f", $scored_flow{$_}->{"score"} / $max_score) } keys %scored_flow;

        do {
                $diff = 0;

                # Assign points to nearest center
                foreach $ip (keys %scored_flow) {
                        my $closest = 0;
                        my $dist = abs $scored_flow{$ip}->{'norm_score'} - $center[$closest];
 
                        foreach (1..$#center) {
                                if (abs $scored_flow{$ip}->{'norm_score'} - $center[$_] < $dist) {
                                        $dist = abs $scored_flow{$ip}->{'norm_score'} - $center[$_];
                                        $closest = $_;
                                }
                        }

                        $scored_flow{$ip}->{"cluster"} = $closest;
                }

                # Compute new centers based on median
                foreach $centroid (0..$#center) {
                        @members = sort map { $scored_flow{$_}->{"norm_score"} }
                                   grep { $scored_flow{$_}->{"cluster"} == $centroid } keys %scored_flow;

                        $pos = int(@members / 2) - 1;
                        if (@members == 0) {
                                $new_center = $center[$centroid];
                        } elsif (@members % 2 == 0) {
                                $new_center = ($members[$pos] + $members[$pos + 1]) / 2;
                        } else {
                                $new_center = $members[$pos];
                        }

                        $diff += abs $center[$centroid] - $new_center;
                        $center[$centroid] = $new_center;
                }
        } while ($diff > 0.01);

        return;
}

1;
