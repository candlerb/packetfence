package pf::node;

=head1 NAME

pf::node - module for node management.

=cut

=head1 DESCRIPTION

pf::node contains the functions necessary to manage node: creation, 
deletion, registration, expiration, read info, ...

=head1 CONFIGURATION AND ENVIRONMENT

Read the F<pf.conf> configuration file.

=cut

use strict;
use warnings;
use Log::Log4perl;
use Log::Log4perl::Level;
use Net::MAC;
use Readonly;

use constant NODE => 'node';

# Node status constants
#FIXME port all hard-coded strings to these constants
Readonly::Scalar our $STATUS_REGISTERED => 'reg';
Readonly::Scalar our $STATUS_UNREGISTERED => 'unreg';
Readonly::Scalar our $STATUS_PENDING => 'pending';
Readonly::Scalar our $STATUS_GRACE => 'grace';

BEGIN {
    use Exporter ();
    our ( @ISA, @EXPORT );
    @ISA = qw(Exporter);
    @EXPORT = qw(
        node_db_prepare
        $node_db_prepared

        node_exist
        node_pid
        node_delete
        node_add
        node_add_simple
        node_attributes
        node_attributes_with_fingerprint
        node_view
        node_count_all
        node_view_all
        node_view_with_fingerprint
        node_modify
        node_register
        node_deregister
        node_unregistered
        nodes_maintenance
        nodes_unregistered
        nodes_registered
        nodes_registered_not_violators
        nodes_active_unregistered
        node_expire_lastarp
        node_cleanup
        node_update_lastarp
        node_mac_wakeup
        is_node_voip
        is_node_registered
        is_max_reg_nodes_reached
    );
}

use pf::config;
use pf::db;
use pf::nodecategory;
use pf::scan qw($SCAN_VID);
use pf::util;
use pf::violation;

# The next two variables and the _prepare sub are required for database handling magic (see pf::db)
our $node_db_prepared = 0;
# in this hash reference we hold the database statements. We pass it to the query handler and he will repopulate
# the hash if required
our $node_statements = {};

=head1 SUBROUTINES

TODO: This list is incomlete

=over

=cut

sub node_db_prepare {
    my $logger = Log::Log4perl::get_logger('pf::node');
    $logger->debug("Preparing pf::node database queries");

    $node_statements->{'node_exist_sql'} = get_db_handle()->prepare(qq[ select mac from node where mac=? ]);

    $node_statements->{'node_pid_sql'} = get_db_handle()->prepare( qq[ select count(*) from node where status='reg' and pid=? ]);

    $node_statements->{'node_add_sql'} = get_db_handle()->prepare(qq[
        INSERT INTO node (
            mac, pid, category_id, status, voip, bypass_vlan,
            detect_date, regdate, unregdate, lastskip, 
            user_agent, computername, dhcp_fingerprint,
            last_arp, last_dhcp,
            notes
        ) VALUES (
            ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
        )
    ]);

    $node_statements->{'node_delete_sql'} = get_db_handle()->prepare(qq[ delete from node where mac=? ]);

    $node_statements->{'node_modify_sql'} = get_db_handle()->prepare(qq[
        UPDATE node SET 
            mac=?, pid=?, category_id=?, status=?, voip=?, bypass_vlan=?,
            detect_date=?, regdate=?, unregdate=?, lastskip=?, 
            user_agent=?, computername=?, dhcp_fingerprint=?, 
            last_arp=?, last_dhcp=?,
            notes=?
        WHERE mac=?
    ]);
 
    $node_statements->{'node_attributes_sql'} = get_db_handle()->prepare(qq[
        SELECT mac, pid, voip, status, bypass_vlan, 
            IF(ISNULL(node_category.name), '', node_category.name) as category, 
            detect_date, regdate, unregdate, lastskip, 
            user_agent, computername, dhcp_fingerprint, 
            last_arp, last_dhcp,
            node.notes
        FROM node
            LEFT JOIN node_category USING (category_id)
        WHERE mac = ?
    ]);
 
    $node_statements->{'node_attributes_with_fingerprint_sql'} = get_db_handle()->prepare(qq[
        SELECT mac, pid, voip, status, bypass_vlan, 
            IF(ISNULL(node_category.name), '', node_category.name) as category, 
            detect_date, regdate, unregdate, lastskip, 
            user_agent, computername, IFNULL(os_class.description, ' ') as dhcp_fingerprint, 
            last_arp, last_dhcp,
            node.notes
        FROM node
            LEFT JOIN node_category USING (category_id)
            LEFT JOIN dhcp_fingerprint ON node.dhcp_fingerprint=dhcp_fingerprint.fingerprint 
            LEFT JOIN os_mapping ON dhcp_fingerprint.os_id=os_mapping.os_type 
            LEFT JOIN os_class ON os_mapping.os_class=os_class.class_id 
        WHERE mac = ?
    ]);

    # DEPRECATED see _node_view_old()
    $node_statements->{'node_view_old_sql'} = get_db_handle()->prepare(qq[
        SELECT node.mac, node.pid, node.voip, node.bypass_vlan, node.status,
            IF(ISNULL(node_category.name), '', node_category.name) as category,
            node.detect_date, node.regdate, node.unregdate, node.lastskip,
            node.user_agent, node.computername, node.dhcp_fingerprint,
            node.last_arp, node.last_dhcp, 
            locationlog.switch as last_switch, locationlog.port as last_port, locationlog.vlan as last_vlan,
            IF(ISNULL(locationlog.connection_type), '', locationlog.connection_type) as last_connection_type,
            locationlog.dot1x_username as last_dot1x_username, locationlog.ssid as last_ssid,
            COUNT(DISTINCT violation.id) as nbopenviolations,
            node.notes
        FROM node
            LEFT JOIN node_category USING (category_id)
            LEFT JOIN violation ON node.mac=violation.mac AND violation.status = 'open'
            LEFT JOIN locationlog ON node.mac=locationlog.mac AND end_time IS NULL
        GROUP BY node.mac
        HAVING node.mac=?
    ]);

    $node_statements->{'node_view_sql'} = get_db_handle()->prepare(<<'    SQL');
        SELECT node.mac, node.pid, node.voip, node.bypass_vlan, node.status,
            IF(ISNULL(node_category.name), '', node_category.name) as category,
            node.detect_date, node.regdate, node.unregdate, node.lastskip,
            node.user_agent, node.computername, node.dhcp_fingerprint,
            node.last_arp, node.last_dhcp,
            node.notes
        FROM node
            LEFT JOIN node_category USING (category_id)
        WHERE node.mac=?
    SQL

    $node_statements->{'node_last_locationlog_sql'} = get_db_handle()->prepare(<<'    SQL');
       SELECT 
           locationlog.switch as last_switch, locationlog.port as last_port, locationlog.vlan as last_vlan,
           IF(ISNULL(locationlog.connection_type), '', locationlog.connection_type) as last_connection_type,
           locationlog.dot1x_username as last_dot1x_username, locationlog.ssid as last_ssid
       FROM locationlog 
       WHERE mac = ? AND end_time IS NULL
    SQL

    # DEPRECATED see node_view_with_fingerprint()'s POD
    $node_statements->{'node_view_with_fingerprint_sql'} = get_db_handle()->prepare(qq[
        SELECT node.mac, node.pid, node.voip, node.bypass_vlan, node.status, 
            IF(ISNULL(node_category.name), '', node_category.name) as category,
            node.detect_date, node.regdate, node.unregdate, node.lastskip, 
            node.user_agent, node.computername, IFNULL(os_class.description, ' ') as dhcp_fingerprint, 
            node.last_arp, node.last_dhcp, 
            locationlog.switch as last_switch, locationlog.port as last_port, locationlog.vlan as last_vlan,
            IF(ISNULL(locationlog.connection_type), '', locationlog.connection_type) as last_connection_type,
            locationlog.dot1x_username as last_dot1x_username, locationlog.ssid as last_ssid,
            COUNT(DISTINCT violation.id) as nbopenviolations,
            node.notes
        FROM node 
            LEFT JOIN node_category USING (category_id) 
            LEFT JOIN dhcp_fingerprint ON node.dhcp_fingerprint=dhcp_fingerprint.fingerprint 
            LEFT JOIN os_mapping ON dhcp_fingerprint.os_id=os_mapping.os_type 
            LEFT JOIN os_class ON os_mapping.os_class=os_class.class_id 
            LEFT JOIN violation ON node.mac=violation.mac AND violation.status = 'open'
            LEFT JOIN locationlog ON node.mac=locationlog.mac AND end_time IS NULL
        GROUP BY node.mac
        HAVING node.mac=?
    ]);

    # This guy here is not in a prepared statement yet, have a look in node_view_all to see why
    $node_statements->{'node_view_all_sql'} = qq[
        SELECT node.mac, node.pid, node.voip, node.bypass_vlan, node.status,
            IF(ISNULL(node_category.name), '', node_category.name) as category,
            node.detect_date, node.regdate, node.unregdate, node.lastskip,
            node.user_agent, node.computername, node.dhcp_fingerprint,
            node.last_arp, node.last_dhcp,
            locationlog.switch as last_switch, locationlog.port as last_port, locationlog.vlan as last_vlan,
            IF(ISNULL(locationlog.connection_type), '', locationlog.connection_type) as last_connection_type,
            locationlog.dot1x_username as last_dot1x_username, locationlog.ssid as last_ssid,
            COUNT(DISTINCT violation.id) as nbopenviolations,
            node.notes
        FROM node
            LEFT JOIN node_category USING (category_id)
            LEFT JOIN violation ON node.mac=violation.mac AND violation.status = 'open'
            LEFT JOIN locationlog ON node.mac=locationlog.mac AND end_time IS NULL
        GROUP BY node.mac
    ];

    # This guy here is special, have a look in node_count_all to see why
    $node_statements->{'node_count_all_sql'} = "select count(*) as nb from node";

    $node_statements->{'node_ungrace_sql'} = get_db_handle()->prepare(
        qq [ select mac from node where status="grace" and unix_timestamp(now())-unix_timestamp(lastskip) > ]
            . $Config{'registration'}{'skip_reminder'});

    $node_statements->{'node_expire_unreg_field_sql'} = get_db_handle()->prepare(
        qq [ select mac from node where status="reg" and unregdate != 0 and unregdate < now() ]);

    $node_statements->{'node_expire_window_sql'} = get_db_handle()->prepare(
        qq [ SELECT mac FROM node WHERE status="reg" AND unix_timestamp(regdate) + ? < unix_timestamp(now()) ]
    );

    $node_statements->{'node_expire_deadline_sql'} = get_db_handle()->prepare(
        qq [ SELECT mac FROM node WHERE status="reg" AND unix_timestamp(regdate) <  ? ]
    );

    $node_statements->{'node_expire_session_sql'} = get_db_handle()->prepare(qq[
        UPDATE node n SET n.status="unreg" 
        WHERE n.status="reg" 
            AND n.mac NOT IN (SELECT i.mac FROM iplog i WHERE (i.end_time=0 OR i.end_time > now()))
            AND n.mac NOT IN (
                SELECT i.mac FROM iplog i WHERE end_time!=0 AND unix_timestamp(now()) - unix_timestamp(i.end_time) < ?
            )
    ]);

    $node_statements->{'node_expire_lastarp_sql'} = get_db_handle()->prepare(
        qq [ select mac from node where unix_timestamp(last_arp) < (unix_timestamp(now()) - ?) and last_arp!=0 ]);

    $node_statements->{'node_expire_lastdhcp_sql'} = get_db_handle()->prepare(
        qq [ select mac from node where unix_timestamp(last_dhcp) < (unix_timestamp(now()) - ?) and last_dhcp !=0 and status="$STATUS_UNREGISTERED" ]);

    $node_statements->{'node_unregistered_sql'} = get_db_handle()->prepare(qq[
        SELECT mac, pid, voip, bypass_vlan, status,
            detect_date, regdate, unregdate, lastskip, 
            user_agent, computername, dhcp_fingerprint, 
            last_arp, last_dhcp,
            notes
        FROM node
        WHERE status = "$STATUS_UNREGISTERED" AND mac = ?
    ]);

    $node_statements->{'nodes_unregistered_sql'} = get_db_handle()->prepare(qq[
        SELECT mac, pid, voip, bypass_vlan, status,
            detect_date, regdate, unregdate, lastskip, 
            user_agent, computername, dhcp_fingerprint, 
            last_arp, last_dhcp,
            notes
        FROM node
        WHERE status = "$STATUS_UNREGISTERED"
    ]);

    $node_statements->{'nodes_registered_sql'} = get_db_handle()->prepare(qq[
        SELECT mac, pid, voip, bypass_vlan, status,
            detect_date, regdate, unregdate, lastskip, 
            user_agent, computername, dhcp_fingerprint, 
            last_arp, last_dhcp,
            notes
        FROM node
        WHERE status = "$STATUS_REGISTERED"
    ]);

    $node_statements->{'nodes_registered_not_violators_sql'} = get_db_handle()->prepare(qq[
        SELECT node.mac FROM node 
            LEFT JOIN violation ON node.mac=violation.mac AND violation.status='open' 
        WHERE node.status='reg' GROUP BY node.mac HAVING count(violation.mac)=0
    ]);

    $node_statements->{'nodes_active_unregistered_sql'} = get_db_handle()->prepare(
        qq [ select n.mac,n.pid,n.detect_date,n.regdate,n.unregdate,n.lastskip,n.status,n.user_agent,n.computername,n.notes,i.ip,i.start_time,i.end_time,n.last_arp from node n left join iplog i on n.mac=i.mac where n.status="unreg" and (i.end_time=0 or i.end_time > now()) ]);

    $node_statements->{'nodes_active_sql'} = get_db_handle()->prepare(
        qq [ select n.mac,n.pid,n.detect_date,n.regdate,n.unregdate,n.lastskip,n.status,n.user_agent,n.computername,n.notes,n.dhcp_fingerprint,i.ip,i.start_time,i.end_time,n.last_arp from node n, iplog i where n.mac=i.mac and (i.end_time=0 or i.end_time > now()) ]);

    $node_statements->{'node_update_lastarp_sql'} = get_db_handle()->prepare(qq [ update node set last_arp=now() where mac=? ]);

    $node_db_prepared = 1;
    return 1;
}

#
# return mac if the node exists
#
sub node_exist {
    my ($mac) = @_;
    my $query = db_query_execute(NODE, $node_statements, 'node_exist_sql', $mac) || return (0);
    my ($val) = $query->fetchrow_array();
    $query->finish();
    return ($val);
}

#
# return number of nodes match that PID
#
sub node_pid {
    my ($pid) = @_;
    my $query = db_query_execute(NODE, $node_statements, 'node_pid_sql', $pid) || return (0);
    my ($count) = $query->fetchrow_array();
    $query->finish();
    return ($count);
}

#
# delete and return 1
#
sub node_delete {
    my ($mac) = @_;
    my $logger = Log::Log4perl::get_logger('pf::node');
    my $tmpMAC = Net::MAC->new( 'mac' => $mac );
    $mac = $tmpMAC->as_IEEE();

    if ( !node_exist($mac) ) {
        $logger->error("delete of non-existent node '$mac' failed");
        return 0;
    }

    require pf::locationlog;
    # TODO that limitation is arbitrary at best, we need to resolve that.
    if ( defined( pf::locationlog::locationlog_view_open_mac($mac) ) ) {
        $logger->warn("$mac has an open locationlog entry. Node deletion prohibited");
        return 0;
    }

    db_query_execute(NODE, $node_statements, 'node_delete_sql', $mac) || return (0);
    $logger->info("node $mac deleted");
    return (1);
}

#
# clean input parameters and add to node table
#
sub node_add {
    my ( $mac, %data ) = @_;

    my $logger = Log::Log4perl::get_logger('pf::node');
    $logger->trace("node add called");

    my $tmpMAC = Net::MAC->new( 'mac' => $mac );
    $mac = $tmpMAC->as_IEEE();
    $mac = lc($mac);
    return (0) if ( !valid_mac($mac) );

    if ( node_exist($mac) ) {
        $logger->warn("attempt to add existing node $mac");

        #return node_modify($mac,%data);
        return (2);
    }

    #foreach my $row (node_desc()){
    #    $data{$row->{'Field'}}="" if (!defined $data{$row->{'Field'}});
    #} 

    foreach my $field (
        'pid', 'voip', 'bypass_vlan', 'status', 
        'detect_date', 'regdate', 'unregdate', 'lastskip',
        'user_agent', 'computername', 'dhcp_fingerprint', 
        'last_arp', 'last_dhcp',
        'notes'
    ) {
        $data{$field} = "" if ( !defined $data{$field} );
    }
    if ( ( $data{status} eq $STATUS_REGISTERED ) && ( $data{regdate} eq '' ) ) {
        $data{regdate} = mysql_date();
    }

    # category handling
    $data{'category_id'} = _node_category_handling(%data);
    if (defined($data{'category_id'}) && $data{'category_id'} == 0) {
        $logger->error("Unable to insert node because specified category doesn't exist");
        return (0);
    }

    db_query_execute(NODE, $node_statements, 'node_add_sql',
        $mac, $data{pid}, $data{category_id}, $data{status}, $data{voip}, $data{bypass_vlan},
        $data{detect_date}, $data{regdate}, $data{unregdate}, $data{lastskip},
        $data{user_agent}, $data{computername}, $data{dhcp_fingerprint}, 
        $data{last_arp}, $data{last_dhcp},
        $data{notes}
    ) || return (0);
    return (1);
}

#
# simple wrapper for pfmon/pfdhcplistener-detected and auto-generated nodes
#
sub node_add_simple {
    my ($mac) = @_;
    my $date  = mysql_date();
    my %tmp   = (
        'pid'         => 1,
        'detect_date' => $date,
        'regdate'     => 0,
        'unregdate'   => 0,
        'last_skip'   => 0,
        'status'      => 'unreg',
        'last_dhcp'   => 0,
        'voip'        => 'no'
    );
    if ( !node_add( $mac, %tmp ) ) {
        return (0);
    } else {
        return (1);
    }
}

=item node_attributes

Returns information about a given MAC address (node)

It's a simpler and faster version of node_view with fewer fields returned.

=cut
sub node_attributes {
    my ($mac) = @_;

    # commented for performance reason and because the calling code is already defensive enough
    # remove comments if necessary (regressions)
    #my $tmpMAC = Net::MAC->new( 'mac' => $mac );
    #$mac = $tmpMAC->as_IEEE();
    my $query = db_query_execute(NODE, $node_statements, 'node_attributes_sql', $mac) || return (0);
    my $ref = $query->fetchrow_hashref();

    # just get one row and finish
    $query->finish();
    return ($ref);
}

=item node_attributes_with_fingerprint

Returns information about a given MAC address (node) with the DHCP
fingerprint class as a string.

It's a simpler and faster version of node_view_with_fingerprint with 
fewer fields returned.

=cut
sub node_attributes_with_fingerprint {
    my ($mac) = @_;

    my $query = db_query_execute(NODE, $node_statements, 'node_attributes_with_fingerprint_sql', $mac) || return (0);
    my $ref = $query->fetchrow_hashref();

    # just get one row and finish
    $query->finish();
    return ($ref);
}

=item _node_view_old

Returning lots of information about a given MAC address (node)

DEPRECATED: This has been kept in case of regressions in the new node_view code.
This code will disappear in 2013.

=cut
sub _node_view_old {
    my ($mac) = @_;

    # Uncomment to log callers
    #my $logger = Log::Log4perl::get_logger('pf::node');
    #my $caller = ( caller(1) )[3] || basename($0);
    #$logger->trace("node_view called from $caller");

    # commented for performance reason and because the calling code is already defensive enough
    # remove comments if necessary (regressions)
    #my $tmpMAC = Net::MAC->new( 'mac' => $mac );
    #$mac = $tmpMAC->as_IEEE();
    my $query = db_query_execute(NODE, $node_statements, 'node_view_old_sql', $mac) || return (0);
    my $ref = $query->fetchrow_hashref();

    # just get one row and finish
    $query->finish();
    return ($ref);
}


=item node_view

Returning lots of information about a given MAC address (node).

New implementation in 3.2.0.

=cut
sub node_view {
    my ($mac) = @_;

    # Uncomment to log callers
    #my $logger = Log::Log4perl::get_logger('pf::node');
    #my $caller = ( caller(1) )[3] || basename($0);
    #$logger->trace("node_view called from $caller");

    my $query = db_query_execute(NODE, $node_statements, 'node_view_sql', $mac) || return (0);
    my $node_info_ref = $query->fetchrow_hashref();
    $query->finish();

    # if no node info returned we exit
    return if (!defined($node_info_ref));

    $query = db_query_execute(NODE, $node_statements, 'node_last_locationlog_sql', $mac) || return (0);
    my $locationlog_info_ref = $query->fetchrow_hashref();
    $query->finish();

    # merge hash references
    # set locationlog info to empty hashref in case result from query was nothing
    $locationlog_info_ref = {} if (!defined($locationlog_info_ref));
    $node_info_ref = { 
        %$node_info_ref, 
        %$locationlog_info_ref,
        'nbopenviolations' => violation_count($mac),
    };

    return ($node_info_ref);
}

sub node_count_all {
    my ( $id, %params ) = @_;
    my $logger = Log::Log4perl::get_logger('pf::node');

    # Hack! we prepare the statement here so that $node_count_all_sql is pre-filled
    node_db_prepare() if (!$node_db_prepared);
    my $node_count_all_sql = $node_statements->{'node_count_all_sql'};

    if ( defined( $params{'where'} ) ) {
        if ( $params{'where'}{'type'} eq 'pid' ) {
            $node_count_all_sql
                .= " WHERE node.pid='" . $params{'where'}{'value'} . "'";
        } elsif ( $params{'where'}{'type'} eq 'category' ) {

            my $cat_id = nodecategory_lookup($params{'where'}{'value'});
            if (!defined($cat_id)) {
                # lets be nice and issue a warning if the category doesn't exist
                $logger->warn("there was a problem looking up category ".$params{'where'}{'value'});
                # put cat_id to 0 so it'll return 0 results (achieving the count ok)
                $cat_id = 0;
            }
            $node_count_all_sql .= " WHERE category_id =" . $cat_id;
        }
    }

    # Hack! Because of the nature of the query built here (we cannot prepare it), we construct it as a string
    # and pf::db will recognize it and prepare it as such
    $node_statements->{'node_count_all_sql_custom'} = $node_count_all_sql;
    return db_data(NODE, $node_statements, 'node_count_all_sql_custom');
}

=item * node_view_all - view all nodes based on several criterias

Warning: The connection_type field is translated into its human form before return.

=cut
sub node_view_all {
    my ( $id, %params ) = @_;
    my $logger = Log::Log4perl::get_logger('pf::node');

    # Hack! we prepare the statement here so that $node_view_all_sql is pre-filled
    node_db_prepare() if (!$node_db_prepared);
    my $node_view_all_sql = $node_statements->{'node_view_all_sql'};

    if ( defined( $params{'where'} ) ) {
        if ( $params{'where'}{'type'} eq 'pid' ) {
            $node_view_all_sql
                .= " HAVING node.pid='" . $params{'where'}{'value'} . "'";

        } elsif ( $params{'where'}{'type'} eq 'category' ) {

            if (!nodecategory_lookup($params{'where'}{'value'})) {
                # lets be nice and issue a warning if the category doesn't exist
                $logger->warn("there was a problem looking up category ".$params{'where'}{'value'});
            }
            $node_view_all_sql .= " HAVING category='" . $params{'where'}{'value'} . "'";

        }
    }
    if ( defined( $params{'orderby'} ) ) {
        $node_view_all_sql .= " " . $params{'orderby'};
    }
    if ( defined( $params{'limit'} ) ) {
        $node_view_all_sql .= " " . $params{'limit'};
    }

    # Hack! Because of the nature of the query built here (we cannot prepare it), we construct it as a string
    # and pf::db will recognize it and prepare it as such
    $node_statements->{'node_view_all_sql_custom'} = $node_view_all_sql;

    require pf::pfcmd::report;
    import pf::pfcmd::report;
    return translate_connection_type(db_data(NODE, $node_statements, 'node_view_all_sql_custom'));
}

=item node_view_with_fingerprint

DEPRECATED: This has been kept in case of regressions in the new 
node_attributes_with_fingerprint code.  This code will disappear in 2013.

=cut
sub node_view_with_fingerprint {
    my ($mac) = @_;
    my $logger = Log::Log4perl::get_logger(__PACKAGE__);

    $logger->warn("DEPRECATED! You should migrate the caller to the faster node_attributes_with_fingerprint");
    my $query = db_query_execute(NODE, $node_statements, 'node_view_with_fingerprint_sql', $mac) || return (0);
    my $ref = $query->fetchrow_hashref();

    # just get one row and finish
    $query->finish();
    return ($ref);
}

sub node_modify {
    my ( $mac, %data ) = @_;

    my $tmpMAC = Net::MAC->new( 'mac' => $mac );
    $mac = $tmpMAC->as_IEEE();
    my $logger = Log::Log4perl::get_logger('pf::node');
    my $auto_registered = 0;

    $mac = lc($mac);
    return (0) if ( !valid_mac($mac) );

    # hack to support an additional autoreg param to the sub without changing the hash to a reference everywhere
    if (defined($data{'auto_registered'})) {
        $auto_registered = 1;
        delete($data{'auto_registered'});
    }

    if ( !node_exist($mac) ) {
        if ( node_add_simple($mac) ) {
            $logger->info(
                "modify of non-existent node $mac attempted - node added");
        } else {
            $logger->error(
                "modify of non-existent node $mac attempted - node add failed"
            );
            return (0);
        }
    }

    my $existing = node_attributes($mac);
    # keep track of status
    my $old_status = $existing->{status};
    # special handling for category to category_id conversion
    $existing->{'category_id'} = nodecategory_lookup($existing->{'category'});
    foreach my $item ( keys(%data) ) {
        $existing->{$item} = $data{$item};
    }

    # category handling 
    # if category was updated, resolve it correctly
    if (defined($data{'category'}) || defined($data{'category_id'})) {
       $existing->{'category_id'} = _node_category_handling(%data);
       if (defined($existing->{'category_id'}) && $existing->{'category_id'} == 0) {
           $logger->error("Unable to modify node because specified category doesn't exist");
           return (0);
       }   
       # once the category conversion is complete, I delete the category entry to avoid complicating things
       delete $existing->{'category'} if defined($existing->{'category'});
    }

    my $new_mac    = lc( $existing->{'mac'} );
    my $new_status = $existing->{'status'};

    if ( $mac ne $new_mac && node_exist($new_mac) ) {
        $logger->error(
            "modify of node $mac to $new_mac conflicts with existing node");
        return (0);
    }

    if (( $existing->{status} eq 'reg' )
        && (   $existing->{regdate} eq '0000-00-00 00:00:00'
            || $existing->{regdate} eq '' )
        )
    {
        $existing->{regdate} = mysql_date();
    }

    # set unregdate if status changed to registered, is not an auto-registration and old unregdate is unset or 0
    if ( !$auto_registered &&  ( $new_status eq 'reg' )
        && ( $old_status ne 'reg' )
        && (   $existing->{unregdate} eq '0000-00-00 00:00:00'
            || $existing->{unregdate} eq '' )
        )
    {
        $logger->debug(
            "changed registration status for mac $new_mac from $old_status to $new_status; unregdate has not been specified -> calculating it now"
        );
        my $expire_mode = $Config{'registration'}{'expire_mode'};
        if (   ( lc($expire_mode) eq 'window' )
            && ( $Config{'registration'}{'expire_window'} > 0 ) )
        {
            $existing->{'unregdate'} = POSIX::strftime(
                "%Y-%m-%d %H:%M:%S",
                localtime( time + $Config{'registration'}{'expire_window'} )
            );
        } elsif (  ( lc($expire_mode) eq 'deadline' )
            && ( $Config{'registration'}{'expire_deadline'} - time > 0 ) )
        {
            $existing->{'unregdate'} = POSIX::strftime( "%Y-%m-%d %H:%M:%S",
                localtime( $Config{'registration'}{'expire_deadline'} ) );
        }
    }

    db_query_execute(NODE, $node_statements, 'node_modify_sql',
        $new_mac, $existing->{pid}, $existing->{category_id}, $existing->{status}, $existing->{voip}, 
        $existing->{bypass_vlan},
        $existing->{detect_date}, $existing->{regdate}, $existing->{unregdate}, $existing->{lastskip}, 
        $existing->{user_agent}, $existing->{computername}, $existing->{dhcp_fingerprint}, 
        $existing->{last_arp}, $existing->{last_dhcp}, 
        $existing->{notes}, 
        $mac
    ) || return (0);

    return (1);
}

sub node_register {
    my ( $mac, $pid, %info ) = @_;
    my $logger = Log::Log4perl::get_logger('pf::node');
    $mac = lc($mac);
    my $auto_registered = 0;

    # hack to support an additional autoreg param to the sub without changing the hash to a reference everywhere
    if (defined($info{'auto_registered'})) {
        $auto_registered = 1;
    }

    # if it's for auto-registration and mac is already registered, we are done
    if ($auto_registered) {
       my $node_info = node_view($mac);
       if (defined($node_info) && (ref($node_info) eq 'HASH') && $node_info->{'status'} eq 'reg') {
           $logger->info("autoregister a node that is already registered, do nothing.");
           return 1;
       }
    }

    require pf::person;
    # do not check for max_node if it's for auto-register
    if (!$auto_registered) {
        if ( is_max_reg_nodes_reached($mac, $pid, $info{'category'}) ) {
            $logger->error( "max nodes per pid met or exceeded - registration of $mac to $pid failed" );
            return (0);
        }
    }

    # create a person entry for pid if it doesn't exist
    if ( !pf::person::person_exist($pid) ) {
        $logger->info("creating person $pid because it doesn't exist");
        pf::person::person_add($pid);
    } else {
        $logger->debug("person $pid already exists");
    }

    $info{'pid'}     = $pid;
    $info{'status'}  = 'reg';
    $info{'regdate'} = mysql_date();

    # note: we ignore expire modes on auto-registration
    if ( ( !$info{'unregdate'} ) || ( !valid_date( $info{'unregdate'} ) ) ) {
        my $expire_mode = $Config{'registration'}{'expire_mode'};
        if ( !$auto_registered && ( lc($expire_mode) eq 'window' )
            && ( $Config{'registration'}{'expire_window'} > 0 ) )
        {
            $info{'unregdate'} = POSIX::strftime(
                "%Y-%m-%d %H:%M:%S",
                localtime( time + $Config{'registration'}{'expire_window'} )
            );
        } elsif ( !$auto_registered && ( lc($expire_mode) eq 'deadline' )
            && ( $Config{'registration'}{'expire_deadline'} - time > 0 ) )
        {
            $info{'unregdate'} = POSIX::strftime( "%Y-%m-%d %H:%M:%S",
                localtime( $Config{'registration'}{'expire_deadline'} ) );
        }
    }

    if ( !node_modify( $mac, %info ) ) {
        $logger->error("modify of node $mac failed");
        return (0);
    }

    if ( !$auto_registered ) {

        # triggering a violation used to communicate the scan to the user
        if ( isenabled($Config{'scan'}{'registration'}) && $Config{'scan'}{'engine'} ne 'none' ) {
            violation_add( $mac, $SCAN_VID );
        }

    }

    return (1);
}

sub node_deregister {
    my ($mac) = @_;
    my $logger = Log::Log4perl::get_logger('pf::node');
    my %info;
    $info{'status'}    = 'unreg';
    $info{'regdate'}   = 0;
    $info{'unregdate'} = 0;
    $info{'lastskip'}  = 0;

    if ( !node_modify( $mac, %info ) ) {
        $logger->error("unable to de-register node $mac");
        return (0);
    }
}

=item * nodes_maintenance - handling deregistration on node expiration and node grace 

called by pfmon daemon every 10 maintenance interval (usually each 10 minutes)

=cut
sub nodes_maintenance {
    my $logger = Log::Log4perl::get_logger('pf::node');

    my $expire_mode = $Config{'registration'}{'expire_mode'};

    $logger->debug("nodes_maintenance called (expire_mode=$expire_mode)");

    my $ungrace_query = db_query_execute(NODE, $node_statements, 'node_ungrace_sql') || return (0);
    while (my $row = $ungrace_query->fetchrow_hashref()) {
        my $currentMac = $row->{mac};
        pf_run("/usr/local/pf/bin/pfcmd manage deregister $currentMac");
        $logger->info("modified $currentMac from status 'grace' to 'unreg'" );
    };

    my $expire_unreg_query = db_query_execute(NODE, $node_statements, 'node_expire_unreg_field_sql') || return (0);
    while (my $row = $expire_unreg_query->fetchrow_hashref()) {
        my $currentMac = $row->{mac};
        pf_run("/usr/local/pf/bin/pfcmd manage deregister $currentMac");
        $logger->info("modified $currentMac from status 'reg' to 'unreg' based on unregdate colum" );
    }

    if ( isdisabled($expire_mode) ) {
        return (1);
    } else {
        if ( ( lc($expire_mode) eq 'window' ) && $Config{'registration'}{'expire_window'} > 0 ) {
            my $expire_window_query = db_query_execute(
                NODE, $node_statements, 'node_expire_window_sql', $Config{'registration'}{'expire_window'}
            ) || return (0);
            while (my $row = $expire_window_query->fetchrow_hashref()) {
                my $currentMac = $row->{mac};
                pf_run("/usr/local/pf/bin/pfcmd manage deregister $currentMac");
                $logger->info("modified $currentMac from status 'reg' to 'unreg' based on expiration window" );
            }

        } elsif ((lc($expire_mode) eq 'deadline' ) && ( time - $Config{'registration'}{'expire_deadline'} > 0 )) {
            my $expire_deadline_query = db_query_execute(
                NODE, $node_statements, 'node_expire_deadline_sql', $Config{'registration'}{'expire_deadline'}
            ) || return (0);
            while (my $row = $expire_deadline_query->fetchrow_hashref()) {
                my $currentMac = $row->{mac};
                pf_run("/usr/local/pf/bin/pfcmd manage deregister $currentMac");
                $logger->info("modified $currentMac from status 'reg' to 'unreg' based on expiration deadline" );
            }

        } elsif ( lc($expire_mode) eq 'session' ) {
            my $expire_session_query = db_query_execute(
                NODE, $node_statements, 'node_expire_session_sql', $Config{'registration'}{'expire_session'}
            ) || return (0);
            my $rows = $expire_session_query->rows;
            $logger->log(
                ( ( $rows > 0 ) ? $INFO : $DEBUG ),
                "modified $rows nodes from status 'reg' to 'unreg' based on session expiration"
            );
        }
    }
    return (1);
}

# check to see is $mac is registered
#
sub node_unregistered {
    my ($mac) = @_;

    my $query = db_query_execute(NODE, $node_statements, 'node_unregistered_sql', $mac) || return (0);
    my $ref = $query->fetchrow_hashref();
    $query->finish();
    return ($ref);
}

sub nodes_unregistered {
    return db_data(NODE, $node_statements, 'nodes_unregistered_sql');
}

sub nodes_registered {
    return db_data(NODE, $node_statements, 'nodes_registered_sql');
}

=item nodes_registered_not_violators

Returns a list of MACs which are registered and don't have any open violation.
Since trap violations stay open, this has the intended effect of getting all MACs which should be allowed through.

=cut
sub nodes_registered_not_violators {
    return db_data(NODE, $node_statements, 'nodes_registered_not_violators_sql');
}

sub nodes_active_unregistered {
    return db_data(NODE, $node_statements, 'nodes_active_unregistered_sql');
}

sub node_expire_lastarp {
    my ($time) = @_;
    return db_data(NODE, $node_statements, 'node_expire_lastarp_sql', $time);
}

sub node_expire_lastdhcp {
    my ($time) = @_;
    return db_data(NODE, $node_statements, 'node_expire_lastdhcp_sql', $time);
}

sub node_cleanup {
    my ($time) = @_;
    my $logger = Log::Log4perl::get_logger('pf::node');
    $logger->debug("calling node_cleanup with time=$time");

    foreach my $row ( node_expire_lastarp($time) ) {
        my $mac = $row->{'mac'};
        $logger->info("mac $mac not seen for $time seconds, deleting");
        node_delete( $row->{'mac'} );
    }

    foreach my $rowVlan ( node_expire_lastdhcp($time) ) {
        my $mac = $rowVlan->{'mac'};
        require pf::locationlog;
        if (pf::locationlog::locationlog_update_end_mac($mac)) {
            $logger->info("mac $mac not seen for $time seconds, deleting");
           node_delete($mac);
        }
    }
    return (0);
}

sub node_update_lastarp {
    my ($mac) = @_;
    db_query_execute(NODE, $node_statements, 'node_update_lastarp_sql', $mac) || return (0);
    return (1);
}

=item * node_mac_wakeup

Sub invoked each time a MAC as activity (eiher from dhcp or traps).

in: mac address

out: void

=cut

sub node_mac_wakeup {
    my ($mac) = @_;
    my $logger = Log::Log4perl::get_logger('pf::node');

    # Is there a violation for the Vendor of this MAC?
    my $dec_oui = macoui2nb($mac);
    $logger->debug( "sending VENDORMAC::$dec_oui trigger" );
    pf::violation::violation_trigger( $mac, $dec_oui, "VENDORMAC" );

    my $dec_mac = mac2nb($mac);
    $logger->debug( "sending MAC::$dec_mac trigger" );
    pf::violation::violation_trigger( $mac, $dec_mac, "MAC" );
}

=item * is_node_voip

Is given MAC a VoIP Device or not?

in: mac address

=cut
sub is_node_voip {
    my ($mac) = @_;
    my $logger = Log::Log4perl::get_logger('pf::node');

    $logger->trace("Asked whether node $mac is a VoIP Device or not");
    my $node_info = node_attributes($mac);   
    if ($node_info->{'voip'} eq $VOIP) {
        return $TRUE;
    } else {
        return $FALSE;
    }
}

=item * is_node_registered

Is given MAC registered or not?

in: mac address

=cut
sub is_node_registered {
    my ($mac) = @_;
    my $logger = Log::Log4perl::get_logger('pf::node');

    $logger->trace("Asked whether node $mac is registered or not");
    my $node_info = node_attributes($mac);   
    if ($node_info->{'status'} eq $STATUS_REGISTERED) {
        return $TRUE;
    } else {
        return $FALSE;
    }
}

=item * node_category_handling - assigns category_id based on provided data

expects category_id or category name in the form of category => 'name' or category_id => id

returns category_id, undef if no category was required or 0 if no category is found (which is a problem)

=cut
sub _node_category_handling {
    my (%data) = @_;
    my $logger = Log::Log4perl::get_logger('pf::node');

    if (defined($data{'category_id'})) {
        # category_id has priority over category
        if (!nodecategory_exist($data{'category_id'})) {
            $logger->debug("Unable to insert node because specified category doesn't exist: ".$data{'category_id'});
            return 0; 
        }

    # web node add will always push category="" so we need to explicitly ignore it
    } elsif (defined($data{'category'}) && $data{'category'} ne '')  {

        # category name into id conversion
        $data{'category_id'} = nodecategory_lookup($data{'category'});
        if (!defined($data{'category_id'}))  {
            $logger->debug("Unable to insert node because specified category doesn't exist: ".$data{'category'});
            return 0;
        }

    } else {
        # if no category is specified then we set to undef so that DBI will insert a NULL
        $data{'category_id'} = undef;
    }
    return $data{'category_id'};
}

=item is_max_reg_nodes_reached

Performs the enforcement of the maximum number of registered nodes allowed per user.

Two techniques so far: a global maxnodes parameter and a per-category maximum.

=cut
sub is_max_reg_nodes_reached {
    my ($mac, $pid, $category) = @_;
    my $logger = Log::Log4perl::get_logger(__PACKAGE__);

    # default_pid is a special case: no limit for this user
    return $FALSE if ($pid eq $default_pid);

    # global max nodes per pid limit
    my $nb_nodes_for_pid = node_pid($pid);
    my $maxnodes = $Config{'registration'}{'maxnodes'};
    if ( $maxnodes != 0 && $nb_nodes_for_pid >= $maxnodes ) {
        $logger->info("global max nodes per-user limit reached: $nb_nodes_for_pid are already registered to $pid");
        return $TRUE;
    }

    # per-category max node per pid limit
    if ( defined($category) ) {

        my $category_info = nodecategory_view_by_name($category);
        if ( defined($category_info->{'max_nodes_per_pid'}) ) {

            my $max_nodes_for_category = $category_info->{'max_nodes_per_pid'};
            if ( $max_nodes_for_category != 0 && $nb_nodes_for_pid >= $max_nodes_for_category ) {
                $logger->info(
                    "per-category max nodes per-user limit reached: $nb_nodes_for_pid are already registered to $pid"
                );
                return $TRUE;
            }
        }
    }

    # fallback to maximum not reached
    return $FALSE;
}

=back

=head1 AUTHOR

David LaPorte <david@davidlaporte.org>

Kevin Amorin <kev@amorin.org>

Dominik Gehl <dgehl@inverse.ca>

Maikel van der Roest <mvdroest@utelisys.com>

Olivier Bilodeau <obilodeau@inverse.ca>

=head1 COPYRIGHT

Copyright (C) 2005 David LaPorte

Copyright (C) 2005 Kevin Amorin

Copyright (C) 2007-2012 Inverse inc.

=head1 LICENSE

This program is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301,
USA.

=cut

1;
