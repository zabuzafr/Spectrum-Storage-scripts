#!/usr/bin/perl
use strict;
use warnings;
use DBI;
use POSIX qw(strftime);
use File::Path qw(make_path);
use GD::Graph::bars;
use GD::Graph::Data;
use Text::Table;

# =============================================================================
# Configuration
# =============================================================================
my $config = {
    tsm_server   => 'localhost',
    tsm_user     => 'admin',
    tsm_password => 'password', # ou utiliser un fichier de mot de passe
    days_to_show => 7,          # 7 ou 30 jours
    output_dir   => '/tmp/tsm_reports',
    graph_width  => 800,
    graph_height => 400,
};

# =============================================================================
# Sous-routines principales
# =============================================================================
sub get_tsm_data {
    my $days = shift;
    my @data;
    
    # Construction de la requête TSM
    my $start_date = strftime("%Y-%m-%d", localtime(time - ($days * 24 * 3600)));
    my $end_date = strftime("%Y-%m-%d", localtime(time));
    
    # Commande TSM pour récupérer les données de volumétrie
    my $tsm_cmd = qq{dsmadmc -id=$config->{tsm_user} -password=$config->{tsm_password} };
    $tsm_cmd   .= qq{-dataonly=yes -commadelimited };
    $tsm_cmd   .= qq{"select date(END_TIME) as backup_date, sum(BYTES)/1024/1024/1024 as GB_backuped };
    $tsm_cmd   .= qq{from summary where ACTIVITY='BACKUP' };
    $tsm_cmd   .= qq{and date(END_TIME) between '$start_date' and '$end_date' };
    $tsm_cmd   .= qq{group by date(END_TIME) order by backup_date"};
    
    # Exécution de la commande TSM
    open my $tsm_output, '-|', $tsm_cmd or die "Impossible d'exécuter TSM: $!";
    
    while (my $line = <$tsm_output>) {
        chomp $line;
        next if $line =~ /backup_date/; # Skip header
        my ($date, $gb) = split /,/, $line;
        push @data, { date => $date, gb => $gb || 0 } if $date;
    }
    close $tsm_output;
    
    return \@data;
}

sub generate_graph {
    my $data_ref = shift;
    my $days = shift;
    
    my @dates = map { $_->{date} } @$data_ref;
    my @gb_values = map { $_->{gb} } @$data_ref;
    
    my $graph = GD::Graph::bars->new($config->{graph_width}, $config->{graph_height});
    $graph->set(
        title          => "Volumétrie des Sauvegardes TSM ($days derniers jours)",
        x_label        => 'Date',
        y_label        => 'Go Sauvegardés',
        transparent    => 0,
        bar_spacing    => 8,
        show_values    => 1,
        values_vertical => 1,
    );
    
    my $graph_data = GD::Graph::Data->new([\@dates, \@gb_values]);
    my $gd = $graph->plot($graph_data) or die $graph->error;
    
    my $graph_file = "$config->{output_dir}/backup_graph_${days}days.png";
    open my $out, '>', $graph_file or die "Impossible de créer $graph_file: $!";
    binmode $out;
    print $out $gd->png;
    close $out;
    
    return $graph_file;
}

sub generate_html_report {
    my $data_ref = shift;
    my $graph_file = shift;
    my $days = shift;
    
    my $report_file = "$config->{output_dir}/backup_report_${days}days.html";
    
    open my $html, '>', $report_file or die "Impossible de créer $report_file: $!";
    
    print $html <<"HTML_HEAD";
<!DOCTYPE html>
<html>
<head>
    <title>Rapport de Sauvegardes TSM</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; }
        .header { background: #2c3e50; color: white; padding: 15px; border-radius: 5px; }
        .summary { background: #ecf0f1; padding: 15px; border-radius: 5px; margin: 10px 0; }
        table { width: 100%; border-collapse: collapse; margin: 15px 0; }
        th, td { padding: 8px; text-align: left; border-bottom: 1px solid #ddd; }
        th { background-color: #3498db; color: white; }
        tr:hover { background-color: #f5f5f5; }
        .graph { text-align: center; margin: 20px 0; }
    </style>
</head>
<body>
    <div class="header">
        <h1>Rapport de Sauvegardes TSM</h1>
        <p>Période: $days derniers jours | Généré le: @{[scalar localtime]}</p>
    </div>
HTML_HEAD

    # Calcul des statistiques
    my $total_gb = 0;
    my $max_gb = 0;
    my $min_gb = 999999;
    my $max_date = '';
    my $min_date = '';
    
    foreach my $day (@$data_ref) {
        $total_gb += $day->{gb};
        if ($day->{gb} > $max_gb) {
            $max_gb = $day->{gb};
            $max_date = $day->{date};
        }
        if ($day->{gb} < $min_gb && $day->{gb} > 0) {
            $min_gb = $day->{gb};
            $min_date = $day->{date};
        }
    }
    
    my $avg_gb = $total_gb / scalar(@$data_ref);
    
    print $html <<"SUMMARY";
    <div class="summary">
        <h2>Résumé</h2>
        <p><strong>Volume total:</strong> @{[sprintf '%.2f', $total_gb]} Go</p>
        <p><strong>Moyenne quotidienne:</strong> @{[sprintf '%.2f', $avg_gb]} Go/jour</p>
        <p><strong>Pic maximum:</strong> @{[sprintf '%.2f', $max_gb]} Go ($max_date)</p>
        <p><strong>Minimum:</strong> @{[sprintf '%.2f', $min_gb]} Go ($min_date)</p>
    </div>
SUMMARY

    # Tableau détaillé
    print $html "<h2>Détail par Jour</h2>\n";
    print $html "<table>\n";
    print $html "<tr><th>Date</th><th>Go Sauvegardés</th><th>Trend</th></tr>\n";
    
    foreach my $day (sort { $a->{date} cmp $b->{date} } @$data_ref) {
        my $trend = $day->{gb} > $avg_gb ? '↑' : '↓';
        print $html "<tr>",
                   "<td>$day->{date}</td>",
                   "<td>@{[sprintf '%.2f', $day->{gb}]}</td>",
                   "<td>$trend</td>",
                   "</tr>\n";
    }
    
    print $html "</table>\n";
    
    # Graphique
    print $html <<"GRAPH";
    <div class="graph">
        <h2>Graphique des Volumes</h2>
        <img src="$graph_file" alt="Graphique des sauvegardes" style="border: 1px solid #ccc; padding: 5px;">
    </div>
GRAPH

    print $html <<"HTML_FOOT";
</body>
</html>
HTML_FOOT

    close $html;
    
    return $report_file;
}

sub send_email_report {
    my $report_file = shift;
    my $days = shift;
    
    # Configuration email (à adapter)
    my $email_config = {
        to      => 'admin@company.com',
        from    => 'tsm-reports@company.com',
        subject => "Rapport de Sauvegardes TSM - $days jours",
    };
    
    # Utilisation de sendmail (exemple)
    open my $sendmail, '| /usr/sbin/sendmail -t' or die "Impossible d'ouvrir sendmail: $!";
    
    print $sendmail <<"EMAIL";
To: $email_config->{to}
From: $email_config->{from}
Subject: $email_config->{subject}
MIME-Version: 1.0
Content-Type: text/html; charset=utf-8

EMAIL

    # Lecture du contenu HTML
    open my $report, '<', $report_file or die "Impossible de lire $report_file: $!";
    while (my $line = <$report>) {
        print $sendmail $line;
    }
    close $report;
    close $sendmail;
}

# =============================================================================
# Programme principal
# =============================================================================
sub main {
    # Création du répertoire de sortie
    make_path($config->{output_dir}) unless -d $config->{output_dir};
    
    print "Génération du rapport pour $config->{days_to_show} jours...\n";
    
    # Récupération des données TSM
    my $backup_data = get_tsm_data($config->{days_to_show});
    
    if (!@$backup_data) {
        die "Aucune donnée de sauvegarde trouvée pour la période spécifiée.\n";
    }
    
    # Génération du graphique
    print "Génération du graphique...\n";
    my $graph_file = generate_graph($backup_data, $config->{days_to_show});
    
    # Génération du rapport HTML
    print "Génération du rapport HTML...\n";
    my $report_file = generate_html_report($backup_data, $graph_file, $config->{days_to_show});
    
    # Envoi email (optionnel - décommentez si besoin)
    # print "Envoi du rapport par email...\n";
    # send_email_report($report_file, $config->{days_to_show});
    
    print "Rapport généré avec succès!\n";
    print "Fichier HTML: $report_file\n";
    print "Graphique: $graph_file\n";
    
    # Affichage du résumé en console
    my $total = 0;
    $total += $_->{gb} for @$backup_data;
    
    print "\n=== RÉSUMÉ ===\n";
    printf "Période: %d jours\n", $config->{days_to_show};
    printf "Volume total: %.2f Go\n", $total;
    printf "Moyenne journalière: %.2f Go\n", $total / scalar(@$backup_data);
}

# =============================================================================
# Exécution
# =============================================================================
main();
