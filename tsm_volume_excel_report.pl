#!/usr/bin/perl
use strict;
use warnings;
use POSIX qw(strftime);
use Excel::Writer::XLSX;
use Text::Table;
use File::Path qw(make_path);

# =============================================================================
# Configuration
# =============================================================================
my $config = {
    tsm_server   => 'localhost',
    tsm_user     => 'admin',
    tsm_password => 'password',    # ou utiliser passwordfile
    days_to_show => 7,             # 7 ou 30 jours
    output_dir   => '/tmp/tsm_reports',
    company_name => 'Votre Société',
};

# =============================================================================
# Sous-routines principales
# =============================================================================
sub get_tsm_data {
    my $days = shift;
    my @data;
    
    my $start_date = strftime("%Y-%m-%d", localtime(time - ($days * 24 * 3600)));
    my $end_date = strftime("%Y-%m-%d", localtime(time));
    
    my $tsm_cmd = qq{dsmadmc -id=$config->{tsm_user} -password=$config->{tsm_password} };
    $tsm_cmd   .= qq{-dataonly=yes -commadelimited };
    $tsm_cmd   .= qq{"select date(END_TIME) as backup_date, };
    $tsm_cmd   .= qq{sum(BYTES)/1024/1024/1024 as GB_backuped, };
    $tsm_cmd   .= qq{count(*) as file_count };
    $tsm_cmd   .= qq{from summary where ACTIVITY='BACKUP' };
    $tsm_cmd   .= qq{and date(END_TIME) between '$start_date' and '$end_date' };
    $tsm_cmd   .= qq{group by date(END_TIME) order by backup_date"};
    
    open my $tsm_output, '-|', $tsm_cmd or die "Impossible d'exécuter TSM: $!";
    
    while (my $line = <$tsm_output>) {
        chomp $line;
        next if $line =~ /backup_date/;
        my ($date, $gb, $files) = split /,/, $line;
        push @data, { 
            date => $date, 
            gb => $gb || 0,
            files => $files || 0 
        } if $date;
    }
    close $tsm_output;
    
    return \@data;
}

sub generate_excel_report {
    my $data_ref = shift;
    my $days = shift;
    
    my $excel_file = "$config->{output_dir}/tsm_backup_report_${days}days.xlsx";
    
    # Création du classeur Excel
    my $workbook = Excel::Writer::XLSX->new($excel_file);
    die "Impossible de créer le fichier Excel: $!" unless $workbook;
    
    # Formatage
    my $header_format = $workbook->add_format(
        bold => 1,
        color => 'white',
        bg_color => '#2C3E50',
        align => 'center',
        border => 1,
    );
    
    my $number_format = $workbook->add_format(
        num_format => '#,##0.00',
        align => 'right',
        border => 1,
    );
    
    my $date_format = $workbook->add_format(
        num_format => 'yyyy-mm-dd',
        align => 'center',
        border => 1,
    );
    
    my $total_format = $workbook->add_format(
        bold => 1,
        bg_color => '#ECF0F1',
        border => 1,
        num_format => '#,##0.00',
    );
    
    # Feuille de données détaillées
    my $worksheet = $workbook->add_worksheet('Détail par Jour');
    $worksheet->set_tab_color('#3498DB');
    
    # En-têtes
    $worksheet->write('A1', 'Date', $header_format);
    $worksheet->write('B1', 'Go Sauvegardés', $header_format);
    $worksheet->write('C1', 'Fichiers', $header_format);
    $worksheet->write('D1', 'Trend', $header_format);
    $worksheet->write('E1', 'Pourcentage', $header_format);
    
    # Données
    my $row = 1;
    my $total_gb = 0;
    my $total_files = 0;
    
    foreach my $day (sort { $a->{date} cmp $b->{date} } @$data_ref) {
        $worksheet->write_date_time($row, 0, $day->{date} . 'T00:00:00', $date_format);
        $worksheet->write_number($row, 1, $day->{gb}, $number_format);
        $worksheet->write_number($row, 2, $day->{files}, $number_format);
        
        $total_gb += $day->{gb};
        $total_files += $day->{files};
        $row++;
    }
    
    # Calcul des pourcentages et trends
    my $avg_gb = $total_gb / scalar(@$data_ref);
    $row = 1;
    
    foreach my $day (@$data_ref) {
        my $percent = ($day->{gb} / $total_gb) * 100;
        my $trend = $day->{gb} > $avg_gb ? '↑' : '↓';
        
        $worksheet->write_string($row, 3, $trend);
        $worksheet->write_number($row, 4, $percent, $number_format);
        $row++;
    }
    
    # Ligne de total
    $worksheet->write($row, 0, 'TOTAL', $total_format);
    $worksheet->write_number($row, 1, $total_gb, $total_format);
    $worksheet->write_number($row, 2, $total_files, $total_format);
    $worksheet->write_string($row, 3, '');
    $worksheet->write_number($row, 4, 100, $total_format);
    
    # Ajustement des colonnes
    $worksheet->set_column('A:A', 12);
    $worksheet->set_column('B:B', 15);
    $worksheet->set_column('C:C', 12);
    $worksheet->set_column('D:D', 8);
    $worksheet->set_column('E:E', 12);
    
    # Feuille de statistiques
    my $stats_sheet = $workbook->add_worksheet('Statistiques');
    $stats_sheet->set_tab_color('#27AE60');
    
    my @stats_data;
    my $max_gb = 0;
    my $min_gb = 999999;
    my $max_date = '';
    my $min_date = '';
    
    foreach my $day (@$data_ref) {
        if ($day->{gb} > $max_gb) {
            $max_gb = $day->{gb};
            $max_date = $day->{date};
        }
        if ($day->{gb} < $min_gb && $day->{gb} > 0) {
            $min_gb = $day->{gb};
            $min_date = $day->{date};
        }
    }
    
    $stats_sheet->write('A1', 'Statistiques des Sauvegardes', $header_format);
    $stats_sheet->write('A2', 'Période analysée:');
    $stats_sheet->write('B2', "$days jours");
    
    $stats_sheet->write('A3', 'Date début:');
    $stats_sheet->write('B3', $data_ref->[0]{date});
    
    $stats_sheet->write('A4', 'Date fin:');
    $stats_sheet->write('B4', $data_ref->[-1]{date});
    
    $stats_sheet->write('A5', 'Volume total:');
    $stats_sheet->write('B5', $total_gb, $number_format);
    $stats_sheet->write('C5', 'Go');
    
    $stats_sheet->write('A6', 'Fichiers total:');
    $stats_sheet->write('B6', $total_files, $number_format);
    $stats_sheet->write('C6', 'fichiers');
    
    $stats_sheet->write('A7', 'Moyenne quotidienne:');
    $stats_sheet->write('B7', $avg_gb, $number_format);
    $stats_sheet->write('C7', 'Go/jour');
    
    $stats_sheet->write('A8', 'Pic maximum:');
    $stats_sheet->write('B8', $max_gb, $number_format);
    $stats_sheet->write('C8', "Go ($max_date)");
    
    $stats_sheet->write('A9', 'Minimum:');
    $stats_sheet->write('B9', $min_gb, $number_format);
    $stats_sheet->write('C9', "Go ($min_date)");
    
    $stats_sheet->write('A10', 'Jours avec backup:');
    $stats_sheet->write('B10', scalar(@$data_ref));
    
    # Graphique (feuille dédiée)
    my $chart_sheet = $workbook->add_worksheet('Graphique');
    $chart_sheet->set_tab_color('#E74C3C');
    
    # Préparation des données pour le graphique
    my @dates = map { $_->{date} } @$data_ref;
    my @gb_values = map { $_->{gb} } @$data_ref;
    
    $chart_sheet->write('A1', 'Date');
    $chart_sheet->write('B1', 'Go Sauvegardés');
    
    for my $i (0 .. $#dates) {
        $chart_sheet->write($i+1, 0, $dates[$i]);
        $chart_sheet->write($i+1, 1, $gb_values[$i]);
    }
    
    # Création du graphique
    my $chart = $workbook->add_chart(type => 'column', embedded => 1);
    
    $chart->set_title({
        name => "Volumétrie des Sauvegardes TSM ($days derniers jours)",
    });
    
    $chart->add_series({
        categories => '=Graphique!$A$2:$A$' . ($#dates + 2),
        values     => '=Graphique!$B$2:$B$' . ($#dates + 2),
        name       => 'Go Sauvegardés',
        data_labels => { value => 1, position => 'outside_end' },
    });
    
    $chart->set_x_axis({
        name => 'Date',
        num_format => 'yyyy-mm-dd',
    });
    
    $chart->set_y_axis({
        name => 'Gigabytes (Go)',
    });
    
    $chart_sheet->insert_chart('D2', $chart, 20, 10);
    
    # Feuille de résumé
    my $summary_sheet = $workbook->add_worksheet('Résumé');
    $summary_sheet->set_tab_color('#F39C12');
    
    $summary_sheet->write('A1', "Rapport de Sauvegardes TSM", $header_format);
    $summary_sheet->write('A2', "Société: $config->{company_name}");
    $summary_sheet->write('A3', "Généré le: " . strftime("%Y-%m-%d %H:%M:%S", localtime));
    $summary_sheet->write('A4', "Période: $days derniers jours");
    $summary_sheet->write('A5', "Serveur TSM: $config->{tsm_server}");
    
    $workbook->close();
    
    return $excel_file;
}

sub generate_console_report {
    my $data_ref = shift;
    my $days = shift;
    
    my $t = Text::Table->new(
        'Date', 'Go Sauvegardés', 'Fichiers', 'Trend'
    );
    
    my $total_gb = 0;
    my $total_files = 0;
    my $avg_gb = 0;
    
    foreach my $day (sort { $a->{date} cmp $b->{date} } @$data_ref) {
        $total_gb += $day->{gb};
        $total_files += $day->{files};
    }
    
    $avg_gb = $total_gb / scalar(@$data_ref);
    
    foreach my $day (sort { $a->{date} cmp $b->{date} } @$data_ref) {
        my $trend = $day->{gb} > $avg_gb ? '↑' : '↓';
        $t->add(
            $day->{date},
            sprintf('%.2f', $day->{gb}),
            $day->{files},
            $trend
        );
    }
    
    print "=" x 60 . "\n";
    print "RAPPORT DE SAUVEGARDES TSM ($days DERNIERS JOURS)\n";
    print "=" x 60 . "\n";
    print $t->draw;
    print "\n";
    
    print "RÉSUMÉ STATISTIQUE:\n";
    print "-" . "-" x 50 . "\n";
    printf "Volume total: %15.2f Go\n", $total_gb;
    printf "Fichiers total: %13d fichiers\n", $total_files;
    printf "Moyenne quotidienne: %9.2f Go/jour\n", $avg_gb;
    printf "Jours avec activité: %8d jours\n", scalar(@$data_ref);
    print "=" x 60 . "\n";
}

# =============================================================================
# Programme principal
# =============================================================================
sub main {
    make_path($config->{output_dir}) unless -d $config->{output_dir};
    
    print "Génération du rapport Excel pour $config->{days_to_show} jours...\n";
    
    my $backup_data = get_tsm_data($config->{days_to_show});
    
    if (!@$backup_data) {
        die "Aucune donnée de sauvegarde trouvée pour la période spécifiée.\n";
    }
    
    # Rapport console
    generate_console_report($backup_data, $config->{days_to_show});
    
    # Rapport Excel
    print "Génération du fichier Excel...\n";
    my $excel_file = generate_excel_report($backup_data, $config->{days_to_show});
    
    print "Rapport généré avec succès!\n";
    print "Fichier Excel: $excel_file\n";
    print "\nPour ouvrir le fichier: libreoffice $excel_file\n";
}

# =============================================================================
# Exécution
# =============================================================================
main();
