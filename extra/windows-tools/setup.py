from distutils.core import setup
import py2exe

setup(console=['adsync/zentyal-pwdsync-hook', 'adsync/zentyal-pwdsync-service'],
      windows=['adsync/zentyal-enable-hook'])

setup(
    name = 'zentyal-migration',
    description = 'Zentyal Migration Tool',
    version = '2.2',

    windows = [
                  {
                      'script': 'gui/zentyal-migration',
                      'icon_resources': [(1, 'gui/zentyal.ico')],
                  }
              ],

    options = {
                  'py2exe': {
                      'packages': 'encodings',
                      'includes': 'cairo, pango, pangocairo, atk, gobject, gio',
                  }
              },

    data_files = [ 'gui/migration.xml' ]
)