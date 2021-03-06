# Copyright (C) 2008-2012 eBox Technologies S.L.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License, version 2, as
# published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
use strict;
use warnings;

package EBox::Mail;
use base qw(EBox::Module::Service EBox::LdapModule EBox::ObjectsObserver
            EBox::UserCorner::Provider EBox::FirewallObserver
            EBox::LogObserver EBox::Report::DiskUsageProvider
            EBox::KerberosModule EBox::SyncFolders::Provider
            EBox::Events::DispatcherProvider);

use EBox::Sudo;
use EBox::Validate qw( :all );
use EBox::Gettext;
use EBox::Config;
use EBox::Menu::Item;
use EBox::Menu::Folder;
use EBox::MailVDomainsLdap;
use EBox::MailUserLdap;
use EBox::MailAliasLdap;
use EBox::MailLogHelper;
use EBox::MailFirewall;
use EBox::Mail::Greylist;
use EBox::Mail::FetchmailLdap;
use EBox::Service;
use EBox::Exceptions::InvalidData;
use EBox::Dashboard::ModuleStatus;
use EBox::Dashboard::Section;
use EBox::ServiceManager;
use EBox::DBEngineFactory;
use EBox::SyncFolders::Folder;

use Error qw( :try );
use Proc::ProcessTable;
use Perl6::Junction qw(all);
use File::Slurp;

use constant MAILMAINCONFFILE         => '/etc/postfix/main.cf';
use constant MAILMASTERCONFFILE       => '/etc/postfix/master.cf';
use constant MASTER_PID_FILE          => '/var/spool/postfix/pid/master.pid';
use constant MAIL_ALIAS_FILE          => '/etc/aliases';
use constant DOVECOT_CONFFILE         => '/etc/dovecot/dovecot.conf';
use constant DOVECOT_LDAP_CONFFILE    =>  '/etc/dovecot/dovecot-ldap.conf';
use constant MAILINIT                 => 'postfix';
use constant BYTES                    => '1048576';
use constant DOVECOT_SERVICE          => 'dovecot';
use constant TRANSPORT_FILE           => '/etc/postfix/transport';
use constant SASL_PASSWD_FILE         => '/etc/postfix/sasl_passwd';
use constant MAILNAME_FILE            => '/etc/mailname';
use constant VDOMAINS_MAILBOXES_DIR   => '/var/vmail';
use constant ARCHIVEMAIL_CRON_FILE    => '/etc/cron.daily/archivemail';
use constant FETCHMAIL_SERVICE        => 'ebox.fetchmail';
use constant ALWAYS_BCC_TABLE_FILE    => '/etc/postfix/alwaysbcc';
use constant SIEVE_SCRIPTS_DIR        => '/var/vmail/sieve';
use constant BOUNCE_ADDRESS_KEY       => 'SMTPOptions/bounceReturnAddress';
use constant BOUNCE_ADDRESS_DEFAULT   => 'noreply@example.com';
use constant KEYTAB_FILE              => '/etc/dovecot/dovecot.keytab';
use constant DOVECOT_PAM              => '/etc/pam.d/dovecot';

use constant SERVICES => ('active', 'filter', 'pop', 'imap', 'sasl');

sub _create
{
    my $class = shift;
    my $self = $class->SUPER::_create(name => 'mail',
                                      printableName => __('Mail'),
                                      @_);

    $self->{vdomains} = new EBox::MailVDomainsLdap;
    $self->{musers} = new EBox::MailUserLdap;
    $self->{malias} = new EBox::MailAliasLdap;
    $self->{greylist} = new EBox::Mail::Greylist;
    $self->{fetchmail} = new EBox::Mail::FetchmailLdap;

    bless($self, $class);
    return $self;
}

# Method: greylist
#
#   return the greylist object
sub greylist
{
    my ($self) = @_;
    return $self->{greylist};
}

# Method: actions
#
#       Override EBox::Module::Service::actions
#
sub actions
{
    return [
            {
              'action' => __('Generate mail aliases'),
              'reason' =>
                __x('Zentyal will execute {cmd}', cmd => '/usr/sbin/postalias /etc/aliases'),

              'module' => 'mail'
            },
            {
              'action' => __('Add LDAP schemas'),
              'reason' => __(
                          'Zentyal will add two LDAP schemas: authldap.ldif and '
                            .'eboximail.ldif.'
              ),
              'module' => 'mail'
            },
            {
              'action' => __('Create certificates'),
              'reason' => __(
                  'Zentyal will create certificates to use in mail services'
              ),
              'module' => 'mail'
            },
            {
              'action' => __('Add fetchmail update cron job'),
              'reason' => __(
                  'Zentyal will schedule a cron job to update fetchmail configuration when the user add external accounts'),
              'module' => 'mail'
            },

    ];
}

# Method: usedFiles
#
#       Override EBox::Module::Service::files
#
sub usedFiles
{
    my ($self) = @_;

    my @greylistFiles =   @{ $self->greylist()->usedFiles() };

    return [
            {
              'file' => MAILMAINCONFFILE,
              'reason' => __('To configure postfix'),
              'module' => 'mail'
            },
            {
              'file' => MAILMASTERCONFFILE,
              'reason' => __(
                         'To define how client programs connect to services in '
                           .' postfix'
              ),
              'module' => 'mail'
            },
            {
              'file' => MAILNAME_FILE,
              'reason' => __('To configure host mail name'),
              'module' => 'mail'
            },
            {
              'file' => MAIL_ALIAS_FILE,
              'reason' => __('To configure postfix aliases'),
              'module' => 'mail'
            },
            {
              'file' => DOVECOT_CONFFILE,
              'reason' => __('To configure dovecot'),
              'module' => 'mail'
            },
            {
              'file' => DOVECOT_LDAP_CONFFILE,
              'reason' =>  __('To configure dovecot to authenticate against LDAP'),
              'module' => 'mail'
            },
            {
              'file' => SASL_PASSWD_FILE,
              'reason' => __('To configure smart host authentication'),
              'module' => 'mail'
            },
            {
              'file' => TRANSPORT_FILE,
              'reason' => __('To configure mail transports'),
              'module' => 'mail'
            },
            {
                file   => DOVECOT_PAM,
                reason => __('To let dovecot authenticate users using PAM'),
                module => 'mail',
            },
            @greylistFiles
    ];
}

# Method: initialSetup
#
# Overrides:
#   EBox::Module::Base::initialSetup
#
sub initialSetup
{
    my ($self, $version) = @_;

    # Execute initial-setup script
    $self->SUPER::initialSetup($version);

    # Create default rules and services
    # only if installing the first time
    unless ($version) {
        my $firewall = EBox::Global->modInstance('firewall');
        $firewall->addServiceRules($self->_serviceRules());
        $firewall->saveConfigRecursive();

        # TODO: We need a mechanism to notify modules when the hostname
        # changes, so this default could be set to the hostname
        $self->set_string(BOUNCE_ADDRESS_KEY, BOUNCE_ADDRESS_DEFAULT);
    }
}

sub _serviceRules
{
    return [
             {
              'name' => 'SMTP',
              'description' => __('Outgoing Mail (SMTP protocol).'),
              'internal' => 1,
              'protocol' => 'tcp',
              'sourcePort' => 'any',
              'destinationPorts' => [ 25, 465  ],
              'rules' => { 'external' => 'accept', 'internal' => 'accept' },
             },
             {
              'name' => 'Incoming Mail',
              'printableName' => __('Incoming Mail'),
              'description' => __('POP, IMAP and SIEVE protocols'),
              'internal' => 1,
              'protocol' => 'tcp',
              'sourcePort' => 'any',
              'destinationPorts' => [ 110, 143,  993, 995, 4190 ],
              'rules' => { 'external' => 'deny', 'internal' => 'accept' },
             },
             {
              'name' => 'Mail Submission',
              'printableName' => __('Mail Submission'),
              'description' => __('Outgoing Mail (Submission protocol).'),
              'internal' => 1,
              'protocol' => 'tcp',
              'sourcePort' => 'any',
              'destinationPorts' => [  587 ],
              'rules' => { 'external' => 'deny', 'internal' => 'accept' },
             },
    ];
}

sub kerberosServicePrincipals
{
    my ($self) = @_;

    my $data = { service    => 'mail',
                 principals => [ 'imap', 'smtp', 'pop' ],
                 keytab     => KEYTAB_FILE,
                 keytabUser => 'dovecot' };
    return $data;
}



# Method: enableActions
#
#       Override EBox::Module::Service::enableActions
#
sub enableActions
{
    my ($self) = @_;

    $self->performLDAPActions();

    # Remove old keytab file
    EBox::Sudo::root('rm -f ' . KEYTAB_FILE);

    # Create the kerberos service princiapl in kerberos,
    # export the keytab and set the permissions
    $self->kerberosCreatePrincipals();

    try {
        my $cmd = 'cp /usr/share/zentyal-mail/dovecot-pam /etc/pam.d/dovecot';
        EBox::Sudo::root($cmd);
    } otherwise {
    };

    # Execute enable-module script
    $self->SUPER::enableActions();
}

#  Method: enableModDepends
#
#   Override EBox::Module::Service::enableModDepends
#
sub enableModDepends
{
    my ($self) = @_;
    my @depends =  ('network', 'users');
    return \@depends;
}

# Method: eventDispatchers
#
# Overrides:
#
#      <EBox::Events::DispatcherProvider::eventDispatchers>
#
sub eventDispatchers
{
    return [ 'Mail' ];
}

# Method: _getIfacesForAddress
#
#  This method returns all interfaces which ip address belongs
#
# Parameters:
#
#               ip - The IP address
#
# Returns:
#
#               array ref - with all interfaces
sub _getIfacesForAddress
{
    my ($self, $ip) = @_;

    my $net = EBox::Global->modInstance('network');
    my @ifaces = ();

    # check if it is a loopback address
    if (EBox::Validate::isIPInNetwork('127.0.0.1', '255.0.0.0', $ip)) {
        return ['lo'];
    }

    foreach my $iface (@{$net->InternalIfaces()}) {
        foreach my $addr (@{$net->ifaceAddresses($iface)}) {
            if (isIPInNetwork($addr->{'address'}, $addr->{'netmask'}, $ip)) {
                push(@ifaces, $iface);
            }
        }
    }

    return \@ifaces;
}

# Method: _setMailConf
#
#  This method creates all configuration files from conf data.
#
sub _setMailConf
{
    my ($self) = @_;

    $self->_setMailname();

    my $daemonUid = getpwnam('daemon');
    my $daemonGid = getgrnam('daemon');
    my $perm      = '0640';


    my $daemonMode = {
                      uid => $daemonUid,
                      gid => $daemonGid,
                      mode => $perm
                     };

    my @array = ();
    my $users = EBox::Global->modInstance('users');

    my $allowedaddrs = "127.0.0.0/8";
    foreach my $addr (@{ $self->allowedAddresses }) {
        $allowedaddrs .= " $addr";
    }

    push (@array, 'bindDN', $users->ldap->roRootDn());
    push (@array, 'bindPW', $users->ldap->getRoPassword());
    push (@array, 'hostname' , $self->_fqdn());
    push (@array, 'mailname' , $self->mailname());
    push (@array, 'vdomainDN', $self->{vdomains}->vdomainDn());
    push (@array, 'relay', $self->relay());
    push (@array, 'relayAuth', $self->relayAuth());
    push (@array, 'maxmsgsize', ($self->getMaxMsgSize() * $self->BYTES));
    push (@array, 'allowed', $allowedaddrs);
    push (@array, 'aliasDN', $self->{malias}->aliasDn());
    push (@array, 'vmaildir', $self->{musers}->DIRVMAIL);
    push (@array, 'usersDN', $users->usersDn());
    push (@array, 'uidvmail', $self->{musers}->uidvmail());
    push (@array, 'gidvmail', $self->{musers}->gidvmail());
    push (@array, 'popssl', $self->pop3s());
    push (@array, 'imapssl', $self->imaps());
    push (@array, 'ldap', $users->ldap->ldapConf());
    push (@array, 'filter', $self->service('filter'));
    push (@array, 'ipfilter', $self->ipfilter());
    push (@array, 'portfilter', $self->portfilter());
    push (@array, 'zarafa', $self->zarafaEnabled());
    my $alwaysBcc = $self->_alwaysBcc();
    push (@array, 'bccMaps' => $alwaysBcc);
    # greylist parameters
    my $greylist = $self->greylist();
    push (@array, 'greylist',     $greylist->isEnabled() );
    push (@array, 'greylistAddr', $greylist->address());
    push (@array, 'greylistPort', $greylist->port());
    $self->writeConfFile(MAILMAINCONFFILE, "mail/main.cf.mas", \@array);

    @array = ();
    push (@array, 'filter', $self->service('filter'));
    push (@array, 'fwport', $self->fwport());
    push (@array, 'ipfilter', $self->ipfilter());
    push (@array, 'zarafa', $self->zarafaEnabled());
    $self->writeConfFile(MAILMASTERCONFFILE, "mail/master.cf.mas", \@array);

    $self->_setHeloChecks();

    if ($alwaysBcc) {
        $self->_setAlwaysBccTable();
    }

    $self->_setAliasTable();

    # dovecot configuration
    $self->_setDovecotConf();

    # sync users with quota conf
    $self->{musers}->regenMaildirQuotas();

    # greylist configuration files
    $greylist->writeConf();

    $self->writeConfFile(SASL_PASSWD_FILE,
                         'mail/sasl_passwd.mas',
                         [
                          relayHost => $self->relay(),
                          relayAuth => $self->relayAuth(),
                         ],
                         {
                          uid  => 0,
                          gid  => 0,
                          mode => '0600',
                         }
                        );

    $self->_setArchivemailConf();

    #my $manager = new EBox::ServiceManager;
    # Do not run postmap if we can't overwrite SASL_PASSWD_FILE
    #unless ($manager->skipModification('mail', SASL_PASSWD_FILE)) {
    EBox::Sudo::root('/usr/sbin/postmap ' . SASL_PASSWD_FILE);
    #}

    my $zarafaEnabled = $self->zarafaEnabled();
    my @zarafaDomains = ();
    @zarafaDomains = $self->zarafaDomains() if $zarafaEnabled;

    $self->{fetchmail}->writeConf(zarafa => $zarafaEnabled, zarafaDomains => @zarafaDomains);

    $self->_setZarafaConf($zarafaEnabled, @zarafaDomains);
}

sub zarafaEnabled
{
    my ($self) = @_;

    my $gl = EBox::Global->getInstance();
    if ( $gl->modExists('zarafa') ) {
        my $zarafa = $gl->modInstance('zarafa');
        return $zarafa->isEnabled();
    }
    return 0;
}

sub zarafaDomains
{
    my $gl = EBox::Global->getInstance();
    my $zarafa = $gl->modInstance('zarafa');
    my @domains = @{$zarafa->model('VMailDomains')->vdomains()};
    return @domains;
}

sub _setZarafaConf
{
    my ($self, $enabled, @domains) = @_;

    if (not $enabled) {
        EBox::Sudo::root('rm -f ' . TRANSPORT_FILE . ' ' . TRANSPORT_FILE . '.db');
        return;
    }

    $self->writeConfFile(TRANSPORT_FILE, 'mail/transport.mas',
                         [
                             domains => \@domains,
                         ],
                         { uid => 0, gid => 0, mode => '0600', },
                        );
    EBox::Sudo::root('/usr/sbin/postmap ' . TRANSPORT_FILE);
}

sub _alwaysBcc
{
    my ($self) = @_;

    my $vdomains = $self->model('VDomains');
    my $alwaysBcc =  $vdomains->alwaysBcc();
    if ($alwaysBcc) {
        return 'hash:' . ALWAYS_BCC_TABLE_FILE;
    }

    return undef;
}

sub _setAlwaysBccTable
{
    my ($self) = @_;
    my $vdomains = $self->model('VDomains');
    my $bccByDomain = $vdomains->alwaysBccByVDomain();

    my $data;
    while (my ($vdomain, $address) = each %{ $bccByDomain }) {
        $data .= "\@$vdomain $address\n";
    }

    EBox::Module::Base::writeFile(ALWAYS_BCC_TABLE_FILE,
                                  $data,
                                  {
                                      uid => 0,
                                      gid => 0,
                                      mode => '0644',
                                  }
                                 );

    my $postmapCmd = '/usr/sbin/postmap hash:' . ALWAYS_BCC_TABLE_FILE;
    EBox::Sudo::root($postmapCmd);

}


sub _setAliasTable
{
    my ($self) = @_;

    my @aliases = File::Slurp::read_file(MAIL_ALIAS_FILE);
    # remove  postmaster alias and text comment added by ebox
    @aliases = grep {
        my $line = $_;
        my $eboxComment = $line =~ m/^#.*eBox/;
        my $postmasterLine = $line =~ m/postmaster:/;
        (not $eboxComment) and (not $postmasterLine)
    } @aliases;


    my $postmasterAddress = $self->postmasterAddress();
    my $aliasesContents = join '', @aliases;
   $aliasesContents .= "#Added by eBox. Postmaster alias will be rewritten in each Zentyal mail system restart but other aliases will be kept\n";
   $aliasesContents .=   "postmaster: $postmasterAddress\n";

    EBox::Module::Base::writeFile(
                                MAIL_ALIAS_FILE,
                                  $aliasesContents,
                                  {
                                   uid => 0,
                                   gid => 0,
                                   mode => '0644',
                                  }
                                 );

    EBox::Sudo::root('postalias ' . MAIL_ALIAS_FILE);
}


sub _setDovecotConf
{
    my ($self) = @_;

    # main dovecot conf file
    my $sysinfo = EBox::Global->modInstance('sysinfo');
    my $users = EBox::Global->modInstance('users');

    my $uid =  scalar(getpwnam('ebox'));
    my $gid = scalar(getgrnam('ebox'));
    my $gssapiHostname = $sysinfo->hostName() . '.' . $sysinfo->hostDomain();

    my @params = ();
    push (@params, uid => $uid);
    push (@params, gid => $gid);
    push (@params, protocols => $self->_retrievalProtocols());
    push (@params, firstValidUid => $uid);
    push (@params, firstValidGid => $gid);
    push (@params, mailboxesDir =>  VDOMAINS_MAILBOXES_DIR);
    push (@params, postmasterAddress => $self->postmasterAddress(0, 1));
    push (@params, antispamPlugin => $self->_getDovecotAntispamPluginConf());
    push (@params, keytabPath => KEYTAB_FILE);
    push (@params, gssapiHostname => $gssapiHostname);

    $self->writeConfFile(DOVECOT_CONFFILE, "mail/dovecot.conf.mas",\@params);

    my $roPwd = $users->ldap->getRoPassword();

    # ldap dovecot conf file
    @params = ();
    push (@params, usersDn      => $users->usersDn());
    push (@params, mailboxesDir =>  VDOMAINS_MAILBOXES_DIR);
    push (@params, zentyalRO    => "cn=zentyalro," . $users->ldap->dn());
    push (@params, zentyalROPwd => $roPwd);
    $self->writeConfFile(DOVECOT_LDAP_CONFFILE, "mail/dovecot-ldap.conf.mas",\@params);
}



sub _getDovecotAntispamPluginConf
{
    my ($self) = @_;

    # FIXME: disabled until dovecot-antispam ubuntu package is fixed
    return { enabled => 0};

    my $global = EBox::Global->getInstance();
    my @mods = grep {
        $_->can('dovecotAntispamPluginConf')
    } @{ $global->modInstances() };

    if (@mods == 0) {
        return { enabled => 0 };
    } elsif (@mods > 0) {
        EBox::warn('More than one module offers configuration for dovecot plugin. We will take the first one');
    }

    my $mod = shift @mods;
    return $mod->dovecotAntispamPluginConf();
}


sub _setArchivemailConf
{
    my ($self) = @_;

    my $smtpOptions      = $self->model('SMTPOptions');
    my $expireDaysTrash = $smtpOptions->expirationForDeleted();
    my $expireDaysSpam  = $smtpOptions->expirationForSpam();

    if ( ($expireDaysTrash == 0) and ($expireDaysSpam == 0) ) {
        # no need to cronjob bz all expiration times are disabled
        EBox::Sudo::root('rm -f ' . ARCHIVEMAIL_CRON_FILE);
        return;
    }



    my @params = (
                  mailDir =>  $self->{musers}->DIRVMAIL,
                  expireDaysTrash  => $expireDaysTrash,
                  expireDaysSpam   => $expireDaysSpam,

                 );

    EBox::Module::Base::writeConfFileNoCheck(ARCHIVEMAIL_CRON_FILE,
                         "mail/archivemail.mas",
                         \@params,
                         {
                          uid => 0,
                          gid => 0,
                          mode => '0755'
                         },
                        );


}



# Method: defaultMailboxQuota
#
#   get the default maximum size for an account's mailbox.
#
#   Returns:
#      the amount in Mb or 0 for unlimited size
sub defaultMailboxQuota
{
    my ($self) = @_;
    my $smtpOptions = $self->model('SMTPOptions');
    return $smtpOptions->mailboxQuota();
}


sub _setMailname
{
    my ($self) = @_;
    my $tmpFile = EBox::Config::tmp() . 'mailname.tmp';

    my $mailname = $self->mailname();
    $mailname .= "\n";

    EBox::Module::Base::writeFile(MAILNAME_FILE,
                                  $mailname,
                                  {
                                      uid => 0,
                                      gid => 0,
                                      mode => '0644'
                                     }
                                 );
}


sub mailname
{
    my ($self) = @_;

    my $smtpOptions = $self->model('SMTPOptions');
    my $mailname = $smtpOptions->customMailname();
    if (not defined $mailname) {
        $mailname = $self->_fqdn();
    }

    return $mailname;
}

sub checkMailname
{
    my ($self, $mailname) = @_;

    if (not $mailname =~ m/\./) {
        my $advice;
        if ($mailname eq $self->_fqdn()) {
            $advice = __(
'Cannot use the hostname as mailname because it is not a fully' .
' qualified name. Please, define a custom server mailname'
                        );
        } else {
            $advice =
                __('The mail name must be a fully qualified name');
        }


        throw EBox::Exceptions::InvalidData(
                                            data => __('Host mail name'),
                                            value => $mailname,
                                            advice => $advice,
                                           );
    }

    # check that the mailname is not equal to any vdomain
    my @vdomains = $self->{vdomains}->vdomains();
    foreach my $vdomain (@vdomains) {
        if ($vdomain eq $mailname) {
            throw EBox::Exceptions::InvalidData(
                                            data => __('Host mail name'),
                                            value => $mailname,
                                            advice =>
__('The mail name and virtual mail domain name are equal')
                                           );
        }
    }


    EBox::Validate::checkDomainName($mailname, __('Host mail name'));

}

sub _setHeloChecks
{
    my ($self) = @_;
    my $fqdn = $self->_fqdn();
    my @params = ( hostnames => [$fqdn]);
     EBox::Module::Base::writeConfFileNoCheck(
                         '/etc/postfix/helo_checks.pcre',
                         'mail/helo_checks.pcre.mas',
                         \@params);
}





sub _retrievalProtocols
{
    my ($self) = @_;

    my $model = $self->model('RetrievalServices');
    return $model->activeProtocols();
}


# Method: pop3
#
#  Returns:
#     bool - wether the POP3 service is enabled
sub pop3
{
    my ($self) = @_;

    my $model = $self->model('RetrievalServices');
    return $model->pop3Value();
}

# Method: pop3s
#
#  Returns:
#     bool - wether the POP3S service is enabled
sub pop3s
{
    my ($self) = @_;

    my $model = $self->model('RetrievalServices');
    return $model->pop3sValue();
}

# Method: imap
#
#  Returns:
#     bool - wether the IMAP service is enabled
sub imap
{
    my ($self) = @_;

    my $model = $self->model('RetrievalServices');
    return $model->imapValue();
}

# Method: imaps
#
#  Returns:
#     bool - whether the IMAPS service is enabled
sub imaps
{
    my ($self) = @_;

    my $model = $self->model('RetrievalServices');
    return $model->imapsValue();
}


# Method: managesieve
#
#  Returns:
#     bool - wether the ManageSieve service is enabled
sub managesieve
{
    my ($self) = @_;

    my $model = $self->model('RetrievalServices');
    return $model->managesieveValue();
}



sub _fqdn
{
    my $fqdn = `hostname --fqdn`;
    if ($? != 0) {
        throw EBox::Exceptions::Internal(
'Zentyal was unable to get the full qualified domain name (FQDN) for his host/'
              .'Please, check than your resolver and /etc/hosts file are properly configured.'
          );
    }

    chomp $fqdn;
    return $fqdn;
}


# this method exists to be used as precondition by the EBox::Mail::Greylist
# package
sub isGreylistEnabled
{
    my ($self) = @_;
    $self->configured() or return undef;
    return $self->greylist()->isEnabled();
}

#  Method: _daemons

#   Override <EBox::Module::Service::_daemons>
#
sub _daemons
{
    my ($self) = @_;

    my $daemons = [
        {
            'name' => MAILINIT,
            'type' => 'init.d',
            'pidfiles' => [MASTER_PID_FILE],
        },
        {
         name => DOVECOT_SERVICE,
        },
        {
            name => FETCHMAIL_SERVICE,
            precondition => \&fetchmailMustRun,
        },

    ];

    my $greylist_daemon = $self->greylist()->daemon();
#    $greylist_daemon->{'precondition'} = \&isGreylistEnabled;
    push(@{$daemons}, $greylist_daemon);

    return $daemons;
}

sub fetchmailMustRun
{
    my ($self) = @_;
    return $self->{fetchmail}->daemonMustRun();
}

sub _dovecotIsRunning
{
    my ($self, $subService) = @_;

    if ($subService) {
        if (not $self->$subService()) {
            # ignore dovecot running status if it is needed for another service
            #   -> dovecot is  needed for smtp auth ad this is always active
            return 0;
        }

    }

    return EBox::Service::running(DOVECOT_SERVICE);
}

sub _postfixIsRunning
{
    my ($self, $service) = @_;
    my $t = new Proc::ProcessTable;
    foreach my $proc (@{$t->table}) {
        ($proc->fname eq 'master') and return 1;
    }
    return undef;
}

#  Method : externalFilter
#
#  return ther name of the external filter used or the name 'custom' in case
#  user's custom settings are in use
sub externalFilter
{
    my ($self) = @_;
    my $mailfilter = EBox::Global->modInstance('mailfilter');
    if ($mailfilter and $mailfilter->isEnabled()) {
        return 'zentyal-mailfilter';
    }


    my $filterModel = $self->model('ExternalFilter');
    return $filterModel->row()->valueByName('externalFilter');
}

sub customFilterInUse
{
    my ($self) = @_;
    return $self->externalFilter() eq 'custom';
}



sub _zentyalMailfilterAttr
{
    my ($self, $attr) = @_;
    my $mailfilter = EBox::Global->modInstance('mailfilter');
    $mailfilter or
        throw EBox::Exceptions::Internal('Mailfilter not installed');

    my ($name, $attrs) = $mailfilter->mailFilter();
    exists $attrs->{$attr}
      or throw EBox::Exceptions::Internal("Attribute $attr does not exist");
    return $attrs->{$attr};
}



# returns wether we must use the filter attr instead of the stored in the
# module's cponfgiuration
sub _useFilterAttr
{
    my ($self) = @_;

    if (not $self->service('filter')) {
        return 0;
    }

    if ($self->externalFilter() eq 'custom') {
        return 0;
    }

    return 1;
}


# Method: ipfilter
#
#  This method returns the ip of the external filter
#
sub ipfilter
{
    my ($self) = @_;

    if ($self->_useFilterAttr) {
        return $self->_zentyalMailfilterAttr('address');
    }

    my $filterModel = $self->model('ExternalFilter');
    return $filterModel->ipfilter();
}



# Method: portfilter
#
#  This method returns the port where the mail filter listen
#
sub portfilter
{
    my ($self) = @_;

    if ($self->_useFilterAttr) {
        return $self->_zentyalMailfilterAttr('port');
    }

    my $filterModel = $self->model('ExternalFilter');
    return $filterModel->portfilter();
}


# Method: fwport
#
#  This method returns the port where forward all messages from external filter
#
sub fwport
{
    my ($self) = @_;

    if ($self->_useFilterAttr) {
        return $self->_zentyalMailfilterAttr('forwardPort');
    }

    my $filterModel = $self->model('ExternalFilter');
    return $filterModel->fwport();
}


# Method: relay
#
#  This method returns the ip address of the smarthost if set
#
sub relay
{
    my ($self) = @_;
    my $smtpOptions = $self->model('SMTPOptions');
    return $smtpOptions->smarthost();
}

# Method: relayAuth
#
#  This method returns the authentication mode used to connect to the smarthost
#
#  Returns:
#      Either undef wether the smarthost does not requires authentication or a
#      hash reference with username and password fields
#
sub relayAuth
{
    my ($self) = @_;
    my $smtpOptions = $self->model('SMTPOptions');
    my $auth = $smtpOptions->row()->elementByName('smarthostAuth');

    my $selectedType = $auth->selectedType();
    if ($selectedType eq 'userandpassword') {
        return $auth->value();
    }

    return undef;
}


# Method: getMaxMsgSize
#
#  This method returns the maximum message size
#
sub getMaxMsgSize
{
    my ($self) = @_;
    my $smtpOptions = $self->model('SMTPOptions');
    return $smtpOptions->maxMsgSize();
}

sub _sslRetrievalServices
{
    my ($self) = @_;
    my $retrievalServices = $self->model('RetrievalServices');
    return $retrievalServices->pop3sValue() or $retrievalServices->imapsValue();
}

#
# Method: allowedAddresses
#
#  Returns the list of allowed objects to relay mail.
#
# Returns:
#
#  array ref - holding the objects
#
sub allowedAddresses
{
    my ($self)  = @_;
    my $objectPolicy = $self->model('ObjectPolicy');
    return $objectPolicy->allowedAddresses();
}

#
# Method: isAllowed
#
#  Checks if a given object is allowed to relay mail.
#
# Parameters:
#
#  object - object name
#
# Returns:
#
#  boolean - true if it's set as allowed, otherwise false
#
sub isAllowed
{
    my ($self, $object)  = @_;
    my $objectPolicy = $self->model('ObjectPolicy');
    return $objectPolicy->isAllowed($object);
}



#
# Method: freeObject
#
#  This method unsets a new allowed object list without the object passed as
#  parameter
#
# Parameters:
#               object - The object to remove.
#
sub freeObject # (object)
{
    my ($self, $object) = @_;
    $object or
        throw EBox::Exceptions::MissingArgument('object');

    my $objectPolicy = $self->model('ObjectPolicy');
    $objectPolicy->freeObject($object);

}

# Method: usesObject
#
#  This methos method returns if the object is on allowed list
#
# Returns:
#
#               bool - true if the object is in allowed list, false otherwise
#
sub usesObject # (object)
{
    my ($self, $object) = @_;
    if ($self->isAllowed($object)) {
        return 1;
    }
    return undef;
}

# Function: usesPort
#
#       Implements EBox::FirewallObserver interface
#
sub usesPort # (protocol, port, iface)
{
    my ($self, $protocol, $port, $iface) = @_;

    my %srvpto = (
                  'active' => 25,
                  'pop'         => 110,
                  'imap'        => 143,
    );

    foreach my $mysrv (keys %srvpto) {
        return 1 if (($port eq $srvpto{$mysrv}) and ($self->service($mysrv)));
    }

    return undef;
}

sub firewallHelper
{
    my $self = shift;
    if ($self->anyDaemonServiceActive()) {
        return new EBox::MailFirewall();
    }
    return undef;
}





sub _dovecotService
{
    my ($self) = @_;

    # if main service is disabled, dovecot too!
    if (not $self->service('active')) {
        return undef;
    }

    return 1;
}

sub _regenConfig
{
    my ($self) = @_;

    return unless $self->configured();

    $self->_preSetConfHook();
    if ($self->service) {
        $self->_setMailConf;
        my $vdomainsLdap = new EBox::MailVDomainsLdap;
        $vdomainsLdap->regenConfig();
    }

    $self->greylist()->writeUpstartFile();
    $self->_enforceServiceState();
    $self->_postSetConfHook();
}


# Method: service
#
#  Returns the state of the service passed as parameter
#
# Parameters:
#
#  service - the service (default: 'active' (main service))
#
# Returns:
#
#  boolean - true if it's active, otherwise false
#
sub service
{
    my ($self, $service) = @_;
    defined($service) or $service = 'active';
    $self->_checkService($service);

    if ($service eq 'active') {
        return $self->isEnabled();
    }
    elsif ($service eq 'sasl') {
        return $self->isEnabled();
    }
    elsif ($service eq 'pop') { # that e
        return $self->model('RetrievalServices')->pop3Value() or
            $self->model('RetrievalServices')->pop3sValue();
    }
    elsif ($service eq 'imap') {
        return $self->model('RetrievalServices')->imapValue() or
            $self->model('RetrievalServices')->imapsValue();
    }
    elsif ($service eq 'filter') {
        return $self->externalFilter() ne 'none';
    }
    else {
        throw EBox::Exceptions::Internal("Unknown service $service");
    }
}





#
# Method: anyDaemonServiceActive
#
#  Returns if any service which a indendent daemon is active
#
# Returns:
#
#  boolean - true if any is active, otherwise false
#
sub anyDaemonServiceActive
{
    my ($self) = @_;
    my @services = ('active', 'pop', 'imap');

    foreach (@services) {
        return 1 if $self->service($_);
    }

    return undef;
}

sub _checkService
{
    my ($self, $service) = @_;

    if ($service ne all(SERVICES)) {
        throw EBox::Exceptions::Internal("Inexistent service $service");
    }
}

# LdapModule implmentation
sub _ldapModImplementation
{
    my $self;

    return new EBox::MailUserLdap();
}

#  Method: notifyAntispamACL
#
#   this method is to notify this module of changes in mailfilter's antispam
#   ACL. This is needed by the greylist service
sub notifyAntispamACL
{
    my ($self) = @_;

    # greylist must be notified of antispam changes
    if (not $self->greylist()->isEnabled()) {
        return;
    }

    $self->setAsChanged();
}


sub mailServicesWidget
{
    my ($self, $widget) = @_;

    $widget->{size} = "'1.5'";
    my $section = new EBox::Dashboard::Section('mailservices', 'Services');
    $widget->add($section);

    my $smtp = new EBox::Dashboard::ModuleStatus(
                                          module => 'mail',
                                          printableName => __('SMTP service'),
                                          running => $self->_postfixIsRunning(),
                                          enabled => $self->service(),
                                        );

    my $pop = new EBox::Dashboard::ModuleStatus(
                                   module => 'mail',
                                   printableName => __('POP3 service'),
                                   running => $self->_dovecotIsRunning('pop3'),
                                   enabled => $self->pop3,
                                          );
    my $pops = new EBox::Dashboard::ModuleStatus(
                                   module => 'mail',
                                   printableName => __('POP3S service'),
                                   running => $self->_dovecotIsRunning('pop3s'),
                                   enabled => $self->pop3s,
                                          );
    my $imap = new EBox::Dashboard::ModuleStatus(
                                    module => 'mail',
                                    printableName => __('IMAP service'),
                                    running => $self->_dovecotIsRunning('imap'),
                                    enabled => $self->imap
                                             );
    my $imaps = new EBox::Dashboard::ModuleStatus(
                                   module => 'mail',
                                   printableName => __('IMAPS service'),
                                   running => $self->_dovecotIsRunning('imaps'),
                                   enabled => $self->imaps
                                             );
    my $greylist = $self->greylist()->serviceWidget();
    my $fetchmailWidget = $self->{fetchmail}->serviceWidget();

    $section->add($smtp);
    $section->add($pop);
    $section->add($pops);
    $section->add($imap);
    $section->add($imaps);
    $section->add($greylist);
    $section->add($fetchmailWidget);

    my $filterSection = $self->_filterDashboardSection();
    $widget->add($filterSection);
}

#
## Method: widgets
#
#       Overriden method that returns summary components
#       for system information
#
sub widgets
{
    return {
        'mail' => {
            'title' => __("Mail"),
            'widget' => \&mailServicesWidget,
            'order' => 8,
            'default' => 1
        }
    };
}

sub _filterDashboardSection
{
    my ($self) = @_;

    my $section = new EBox::Dashboard::Section('mailfilter', 'Mail filter');

    my $service     = $self->service('filter');
    my $statusValue =  $service ? __('enabled') : __('disabled');

    $section->add( new EBox::Dashboard::Value( __('Status'), $statusValue));

    $section->add(
            new EBox::Dashboard::Value(__(q{Mail server's filter}),
                $statusValue)
            );

    $service or return $section;

    my $filter = $self->externalFilter();

    if ($filter eq 'custom') {
        $section->add(new EBox::Dashboard::Value(__('Filter type') =>
            __('Custom')));
        my $address = $self->ipfilter() . ':' . $self->portfilter();
        $section->add(new EBox::Dashboard::Value(__('Address') => $address));
    }else {
        $section->add(
                new EBox::Dashboard::Value(
                    __('Filter type') => $self->_zentyalMailfilterAttr('prettyName')
                    )
                );

# FIXME: this crashes, and maybe it's not needed
#        my $global = EBox::Global->getInstance(1);
#        my ($filterInstance) =
#          grep {$_->mailFilterName eq $filter}
#          @{  $global->modInstancesOfType('EBox::Mail::FilterProvider')  };
#        $filterInstance->mailFilterDashboard($section);
    }

    return $section;
}

sub menu
{
    my ($self, $root) = @_;

    my $folder = new EBox::Menu::Folder(
                                        'name' => 'Mail',
                                        'text' => $self->printableName(),
                                        'separator' => 'Communications',
                                        'order' => 610
    );

    $folder->add(
                 new EBox::Menu::Item(
                                      'url' => 'Mail/Composite/General',
                                      'text' => __('General')
                 )
    );

    $folder->add(
                 new EBox::Menu::Item(
                                      'url' => 'Mail/View/VDomains',
                                      'text' => __('Virtual Mail Domains')
                 )
    );
    $folder->add(
                 new EBox::Menu::Item(
                                      'url' => 'Mail/View/GreylistConfiguration',
                                      'text' => __('Greylist')
                                     ),
                );
    $folder->add(
                 new EBox::Menu::Item(
                                      'url' => 'Mail/QueueManager',
                                      'text' => __('Queue Management')
                 )
    );

    # add filterproviders menu items
    my $global = EBox::Global->getInstance(1);
    my @mods = @{$global->modInstancesOfType('EBox::Mail::FilterProvider')};
    foreach my $mod (@mods) {
        my $menuItem = $mod->mailMenuItem();
        defined $menuItem
          or next;
        $folder->add($menuItem);
    }

    $root->add($folder);
}


# Method: userMenu
#
#   This function returns is similar to EBox::Module::Base::menu but
#   returns UserCorner CGIs for the Zentyal UserCorner. Override as needed.
sub userMenu
{
    my ($self, $root) = @_;

    $root->add(new EBox::Menu::Item('url' => 'Mail/View/ExternalAccounts',
                                    'text' => __('Mail retrieval from external accounts')));
}


sub wizardPages
{
    my ($self) = @_;

    return [{ page => '/Mail/Wizard/VirtualDomain', order => 400 }];
}


sub tableInfo
{
    my $self = shift;
    my $titles = {
                   'timestamp' => __('Date'),
                   'message_id' => __('Message ID'),
                   'from_address' => __('From'),
                   'to_address' => __('To'),
                   'client_host_name' => __('From hostname'),
                   'client_host_ip' => __('From host ip'),
                   'message_size' => __('Size (bytes)'),
                   'relay' => __('Relay'),
                   'message_type' => __('Message type'),
                   'status' => __('Status'),
                   'event' => __('Event'),
                   'message' => __('Additional Info')
    };
    my @order = (
                 'timestamp', 'from_address',
                 'to_address', 'client_host_ip',
                 'message_size', 'relay', 'message_type',
                 'status', 'event',
                 'message'
    );

    my $events = {
                   'msgsent' => __('Successful messages'),
                   'maxmsgsize' => __('Maximum message size exceeded'),
                   'maxusrsize' => __('User quota exceeded'),
                   'norelay' => __('Relay access denied'),
                   'noaccount' => __('Account does not exist'),
                   'nohost' => __('Host unreachable'),
                   'noauth' => __('Authentication error'),
                   'greylist' => __('Greylisted'),
                   'nosmarthostrelay' => __('Relay rejected by the smarthost'),
                   'other' => __('Other events'),
    };

    return [{
            'name' => __('Mail'),
            'tablename' => 'mail_message',
            'titles' => $titles,
            'order' => \@order,
            'filter' => ['from_address', 'to_address', 'status'],
            'types' => { 'client_host_ip' => 'IPAddr' },
            'events' => $events,
            'eventcol' => 'event',
            'consolidate' => $self->consolidate(),
    }];
}


sub consolidate
{
    my ($self) = @_;
    my %vdomains = map { $_ => 1 } $self->{vdomains}->vdomains();


    my $table = 'mail_message_traffic';

    my $isAddrInVD = sub {
        my ($addr) = @_;
        if (defined $addr) {
            my ($user, $vd) = split '@', $addr;
            if (defined($vd) and exists $vdomains{$vd}) {
                return $vd;
            }
        }

        return undef;
    };


    my $spec=  {
            consolidateColumns => {
                quote => {
                          to_address => 1,
                          from_address => 1,
                         },
                event => {
                    accummulate => sub {
                        my ($value, $row) = @_;
                        if ($value eq 'msgsent') {
                            my $toAddr = $row->{to_address};
                            if ($isAddrInVD->($toAddr)) {
                                return 'received';
                            }

                            return 'sent';

                        } else {
                            return 'rejected';
                        }
                    },
                    conversor => sub { return 1  },
                   }, # end event column

                   from_address => {
                       destination => 'vdomain',
                       conversor => sub {
                           my ($value, $row) = @_;
                           my $vd;
                           $vd = $isAddrInVD->($row->{from_address});
                           if ($vd) {
                               return $vd;
                           }

                           $vd = $isAddrInVD->($row->{to_address});
                           if ($vd) {
                               return $vd;
                           }

                           return '-';
                       }
                      }, # end from_address column
            }, # end consoldiateColumns section

           accummulateColumns    => {
                      sent  => 0,
                      received  => 0,
                      rejected  => 0,
              },

            filter => sub {
                  my ($row) = @_;
                  return $row->{event} ne 'other';
              },

           };

    return {  $table => $spec };
}


sub logHelper
{
    my ($self) = @_;

    return new EBox::MailLogHelper();
}

sub restoreConfig
{
    my ($self, $dir) = @_;

    # recreate maildirs for accounts if needed
    my @vdomains = $self->{vdomains}->vdomains();
    foreach my $vdomain (@vdomains) {
        my @addresses =
          values %{ $self->{musers}->allAccountsFromVDomain($vdomain) };
        foreach my $addr (@addresses) {
            my ($left, $right) = split '@', $addr, 2;
            my $maildir = $self->{musers}->maildir($left, $right);
            if (not -d $maildir) {
                $self->{musers}->_createMaildir($left, $right);
            }
        }
    }

}

# backup stuff

sub backupDomains
{
    my $name = 'mailboxes';
    my %attrs  = (
                  printableName => __('Mailboxes'),
                  description   => __(q{Mail messages from users and group alias}),
                 );

    return ($name, \%attrs);
}

sub backupDomainsFileSelection
{
    my ($self, %enabled) = @_;
    if ($enabled{mailboxes}) {
        my $selection = {
                          includes => [ $self->_storageMailDirs() ],
                         };
        return $selection;
    }

    return {};
}

sub _storageMailDirs
{
    return  (qw(/var/mail /var/vmail));
}

# Overrides:
#   EBox::Report::DiskUsageProvider::_facilitiesForDiskUsage
sub _facilitiesForDiskUsage
{
    my ($self) = @_;

    my $printableName = __('Mailboxes');

    return {$printableName => [ $self->_storageMailDirs() ],};
}

# Method: certificates
#
#   This method is used to tell the CA module which certificates
#   and its properties we want to issue for this service module.
#
# Returns:
#
#   An array ref of hashes containing the following:
#
#       service - name of the service using the certificate
#       path    - full path to store this certificate
#       user    - user owner for this certificate file
#       group   - group owner for this certificate file
#       mode    - permission mode for this certificate file
#
sub certificates
{
    my ($self) = @_;

    return [
            {
             serviceId => 'Mail SMTP server',
             service =>  __('Mail SMTP server'),
             path    =>  '/etc/postfix/sasl/postfix.pem',
             user => 'root',
             group => 'root',
             mode => '0400',
            },
            {
             serviceId => 'Mail POP/IMAP server',
             service =>  __('Mail POP/IMAP server'),
             path    =>  '/etc/dovecot/ssl/dovecot.pem',
             user => 'root',
             group => 'root',
             mode => '0400',
            },
           ];
}


sub fetchmailPollTime
{
    my ($self) = @_;
    my $smtpOptions = $self->model('SMTPOptions');
    return $smtpOptions->row()->valueByName('fetchmailPollTime');
}

sub fetchmailRegenTs
{
    my ($self) = @_;
    my $ts =  $self->st_get_int('fetchmailRegenTs');
    defined $ts or
        $ts = 0;
    return $ts;
}

sub setFetchmailRegenTs
{
    my ($self, $ts) = @_;
    $self->st_set_int('fetchmailRegenTs', $ts);
}

sub postmasterAddress
{
    my ($self, $alwaysFqdn, $notUnaliasLocal) = @_;
    my $smtpOptions = $self->model('SMTPOptions');
    my $address = $smtpOptions->postmasterAddress();
    if (($notUnaliasLocal) and  ($address eq 'root')) {
        # not need to unalias root
        $address = 'postmaster';
    }

    if (not $alwaysFqdn) {
        return $address;
    }

    if ($address =~ m/@/) {
        return $address;
    }

    my $mailname = $self->mailname();

    return $address . '@' .  $mailname;
}

# Implement EBox::SyncFolders::Provider interface
sub syncFolders
{
    my ($self) = @_;

    my @folders;

    if ($self->recoveryEnabled()) {
        foreach my $dir ($self->_storageMailDirs()) {
            push (@folders, new EBox::SyncFolders::Folder($dir, 'recovery'));
        }
    }

    return \@folders;
}

sub recoveryDomainName
{
    return __('Mailboxes');
}

sub preSlaveSetup
{
    my ($self, $master) = @_;
    if ($master ne 'zentyal') {
        return;
    }

    # remove vdomains
    $self->model('VDomains')->removeAll(1);
}

sub slaveSetup
{
    my ($self) = @_;

    # regenerate mail ldap tree
    EBox::Sudo::root('/usr/share/zentyal-mail/mail-ldap update');

    $self->SUPER::slaveSetup();
}

sub slaveSetupWarning
{
    my ($self, $master) = @_;
    if (not $self->configured()) {
        return undef;
    }
    if ($master ne 'zentyal') {
        return undef;
    }
    my $vdomainsModel = $self->model('VDomains');
    if ($vdomainsModel->size() == 0) {
        return undef;
    }

    return __('The mail domains and its accounts will be removed when the slave setup is complete');
}

1;
