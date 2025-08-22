#!/usr/bin/perl
use strict;
use warnings;
use POSIX qw(strftime);
use Text::Table;
use File::Path qw(make_path);

# =============================================================================
# Configuration
# =============================================================================
my $config = {
    tsm_server   => 'localhost',
    tsm_user     => 'admin',
    tsm_password => 'password',    # ou utiliser passwordfile
    output_dir   => '/tmp/tsm_audit',
    max_days     => 90,            # Alertes si > 90 jours sans backup
};

# =============================================================================
# Sous-routines principales
# =============================================================================
sub get_retention_violations {
    my $violations = [];
    
    # 1. Vérifier les nodes sans backup récent
    my $nodes_cmd = qq{dsmadmc -id=$config->{tsm_user} -password=$config->{tsm_password} };
    $nodes_cmd   .= qq{-dataonly=yes -commadelimited };
    $nodes_cmd   .= qq{"select node_name, max(END_TIME) as last_backup, };
    $nodes_cmd   .= qq{DATEDIFF(DAY, max(END_TIME), CURRENT_DATE) as days_since_backup };
    $nodes_cmd   .= qq{from summary where ACTIVITY='BACKUP' };
    $nodes_cmd   .= qq{group by node_name };
    $nodes_cmd   .= qq{having DATEDIFF(DAY, max(END_TIME), CURRENT_DATE) > $config->{max_days} };
    $nodes_cmd   .= qq{or max(END_TIME) is null"};
    
    open my $nodes_output, '-|', $nodes_cmd or die "Impossible d'exécuter TSM: $!";
    
    while (my $line = <$nodes_output>) {
        chomp $line;
        next if $line =~ /node_name/;
        my ($node, $last_backup, $days_since) = split /,/, $line;
        
        push @$violations, {
            type => 'NODE_NO_RECENT_BACKUP',
            node => $node,
            last_backup => $last_backup,
            days_since => $days_since,
            severity => $days_since > 180 ? 'CRITICAL' : 'WARNING',
        };
    }
    close $nodes_output;
    
    # 2. Vérifier les policies sans copies de sauvegarde
    my $policies_cmd = qq{dsmadmc -id=$config->{tsm_user} -password=$config->{tsm_password} };
    $policies_cmd   .= qq{-dataonly=yes -commadelimited };
    $policies_cmd   .= qq{"select distinct domain_name, set_name, mgmt_class_name };
    $policies_cmd   .= qq{from policies where destination is null "};
    
    open my $policies_output, '-|', $policies_cmd or die "Impossible d'exécuter TSM: $!";
    
    while (my $line = <$policies_output>) {
        chomp $line;
        next if $line =~ /domain_name/;
        my ($domain, $set, $mgmt_class) = split /,/, $line;
        
        push @$violations, {
            type => 'POLICY_NO_BACKUP_COPY',
            domain => $domain,
            set => $set,
            mgmt_class => $mgmt_class,
            severity => 'HIGH',
        };
    }
    close $policies_output;
    
    # 3. Vérifier les copies expirées
    my $expired_cmd = qq{dsmadmc -id=$config->{tsm_user} -password=$config->{tsm_password} };
    $expired_cmd   .= qq{-dataonly=yes -commadelimited };
    $expired_cmd   .= qq{"select node_name, count(*) as expired_files };
    $expired_cmd   .= qq{from backups where expire_date < CURRENT_DATE };
    $expired_cmd   .= qq{group by node_name having count(*) > 0"};
    
    open my $expired_output, '-|', $expired_cmd or die "Impossible d'exécuter TSM: $!";
    
    while (my $line = <$expired_output>) {
        chomp $line;
        next if $line =~ /node_name/;
        my ($node, $expired_count) = split /,/, $line;
        
        push @$violations, {
            type => 'EXPIRED_BACKUPS',
            node => $node,
            expired_count => $expired_count,
            severity => 'MEDIUM',
        };
    }
    close $expired_output;
    
    return $violations;
}

sub generate_html_report {
    my $violations = shift;
    my $report_file = "$config->{output_dir}/retention_violations.html";
    
    open my $html, '>', $report_file or die "Impossible de créer $report_file: $!";
    
    print $html <<"HTML_HEAD";
<!DOCTYPE html>
<html>
<head>
    <title>Audit des Politiques de Rétention TSM</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; }
        .header { background: #2c3e50; color: white; padding: 15px; border-radius: 5px; }
        .critical { background: #e74c3c; color: white; }
        .high { background: #e67e22; color: white; }
        .medium { background: #f39c12; color: white; }
        .warning { background: #f1c40f; color: black; }
        table { width: 100%; border-collapse: collapse; margin: 15px 0; }
        th, td { padding: 8px; text-align: left; border-bottom: 1px solid #ddd; }
        th { background-color: #3498db; color: white; }
    </style>
</head>
<body>
    <div class="header">
        <h1>Audit des Politiques de Rétention TSM</h1>
        <p>Généré le: @{[scalar localtime]}</p>
    </div>
HTML_HEAD

    # Statistiques
    my %stats = (CRITICAL => 0, HIGH => 0, MEDIUM => 0, WARNING => 0);
    $stats{$_->{severity}}++ for @$violations;
    
    print $html <<"STATS";
    <div style="background: #ecf0f1; padding: 15px; border-radius: 5px; margin: 10px 0;">
        <h2>Résumé</h2>
        <p>Total des violations: <b>@{[scalar @$violations]}</b></p>
        <p>Critique: <span class="critical">$stats{CRITICAL}</span> | 
           Haute: <span class="high">$stats{HIGH}</span> | 
           Moyenne: <span class="medium">$stats{MEDIUM}</span> | 
           Avertissement: <span class="warning">$stats{WARNING}</span></p>
    </div>
STATS

    # Détail des violations
    print $html "<h2>Détail des Violations</h2>\n";
    print $html "<table>\n";
    print $html "<tr><th>Type</th><th>Élément</th><th>Détails</th><th>Sévérité</th></tr>\n";
    
    foreach my $viol (sort { $b->{severity} cmp $a->{severity} || $a->{type} cmp $b->{type} } @$violations) {
        my $details = '';
        my $element = '';
        
        if ($viol->{type} eq 'NODE_NO_RECENT_BACKUP') {
            $element = $viol->{node};
            $details = "Dernier backup: $viol->{last_backup} ($viol->{days_since} jours)";
        }
        elsif ($viol->{type} eq 'POLICY_NO_BACKUP_COPY') {
            $element = "$viol->{domain}/$viol->{set}";
            $details = "Management Class: $viol->{mgmt_class}";
        }
        elsif ($viol->{type} eq 'EXPIRED_BACKUPS') {
            $element = $viol->{node};
            $details = "$viol->{expired_count} fichiers expirés";
        }
        
        print $html "<tr class=\"$viol->{severity}\">",
                   "<td>$viol->{type}</td>",
                   "<td>$element</td>",
                   "<td>$details</td>",
                   "<td><span class=\"$viol->{severity}\">$viol->{severity}</span></td>",
                   "</tr>\n";
    }
    
    print $html "</table>\n";
    print $html "</body></html>";
    close $html;
    
    return $report_file;
}

sub generate_csv_report {
    my $violations = shift;
    my $csv_file = "$config->{output_dir}/retention_violations.csv";
    
    open my $csv, '>', $csv_file or die "Impossible de créer $csv_file: $!";
    
    print $csv "Type,Element,Details,Severity,Timestamp\n";
    
    foreach my $viol (@$violations) {
        my $details = '';
        my $element = '';
        
        if ($viol->{type} eq 'NODE_NO_RECENT_BACKUP') {
            $element = $viol->{node};
            $details = "Last backup: $viol->{last_backup}, Days since: $viol->{days_since}";
        }
        elsif ($viol->{type} eq 'POLICY_NO_BACKUP_COPY') {
            $element = "$viol->{domain}/$viol->{set}";
            $details = "Management Class: $viol->{mgmt_class}";
        }
        elsif ($viol->{type} eq 'EXPIRED_BACKUPS') {
            $element = $viol->{node};
            $details = "Expired files: $viol->{expired_count}";
        }
        
        print $csv "\"$viol->{type}\",\"$element\",\"$details\",\"$viol->{severity}\",\"@{[scalar localtime]}\"\n";
    }
    
    close $csv;
    return $csv_file;
}

sub send_alert {
    my $violations = shift;
    my $critical_count = grep { $_->{severity} eq 'CRITICAL' } @$violations;
    
    if ($critical_count > 0) {
        print "ALERTE: $critical_count violation(s) critique(s) détectée(s)!\n";
        # Ici vous pouvez ajouter l'envoi d'email ou d'alerte
        # system("echo 'Alertes critiques TSM' | mailx -s 'ALERTE TSM' admin\@company.com");
    }
}

# =============================================================================
# Programme principal
# =============================================================================
sub main {
    make_path($config->{output_dir}) unless -d $config->{output_dir};
    
    print "Audit des politiques de rétention TSM...\n";
    print "Recherche des violations (plus de $config->{max_days} jours sans backup)...\n";
    
    my $violations = get_retention_violations();
    
    if (!@$violations) {
        print "Aucune violation de politique de rétention détectée. 👍\n";
        exit 0;
    }
    
    print "Violations détectées: " . scalar(@$violations) . "\n";
    
    # Génération des rapports
    my $html_report = generate_html_report($violations);
    my $csv_report = generate_csv_report($violations);
    
    # Envoi d'alertes
    send_alert($violations);
    
    print "Rapports générés:\n";
    print "  - HTML: $html_report\n";
    print "  - CSV:  $csv_report\n";
    print "\nRésumé des violations:\n";
    
    # Affichage console
    my $t = Text::Table->new('Sévérité', 'Type', 'Élément', 'Détails');
    
    foreach my $viol (sort { $b->{severity} cmp $a->{severity} } @$violations) {
        my $details = '';
        
        if ($viol->{type} eq 'NODE_NO_RECENT_BACKUP') {
            $details = "$viol->{days_since} jours sans backup";
        }
        elsif ($viol->{type} eq 'POLICY_NO_BACKUP_COPY') {
            $details = "Pas de copie de backup configurée";
        }
        elsif ($viol->{type} eq 'EXPIRED_BACKUPS') {
            $details = "$viol->{expired_count} fichiers expirés";
        }
        
        $t->add($viol->{severity}, $viol->{type}, $viol->{node} || $viol->{domain}, $details);
    }
    
    print $t->draw;
}

main();
