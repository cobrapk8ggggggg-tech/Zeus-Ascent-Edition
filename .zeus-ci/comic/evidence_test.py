"""Regressions for evidence provenance; synthetic logs must not claim live success."""
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

spec=importlib.util.spec_from_file_location('sim_probe',Path(__file__).with_name('sim_probe.py'))
probe=importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)

class EvidenceTests(unittest.TestCase):
    def run_probe(self,names,**flags):
        with tempfile.TemporaryDirectory() as root:
            log=Path(root)/'run.log';out=Path(root)/'evidence.json'
            log.write_text('\n'.join("Test Case '-[ZEUSNextTests.NativeComicTranslationTests "+name+"]' passed (0.1 seconds)." for name in names))
            probe.main(log,out,**flags)
            return json.loads(out.read_text())

    def test_simulator_log_never_proves_network_or_other_jobs(self):
        evidence=self.run_probe(probe.CORE)
        self.assertEqual(evidence['passed_tests'],['simulator'])
        self.assertFalse(evidence['physical_device'])
        self.assertFalse(evidence['quality_equivalence_proven'])
        self.assertNotIn(probe.PADDLE,evidence['core_passed'])

    def test_cross_origin_pipeline_must_actually_run(self):
        with self.assertRaises(SystemExit):
            self.run_probe([name for name in probe.CORE if name!='testCrossOriginNoReferrerImagesTranslateThroughNativeFetch'])

    def test_upstream_jobs_require_explicit_success(self):
        evidence=self.run_probe(probe.CORE,bridge_passed=True,decoder_passed=True)
        self.assertEqual(set(evidence['passed_tests']),{'bridge','decoder','simulator'})
        self.assertNotIn('live',evidence['passed_tests'])

    def test_failed_test_is_never_counted_as_passed(self):
        with tempfile.TemporaryDirectory() as root:
            log=Path(root)/'run.log'
            log.write_text('\n'.join("Test Case '-[ZEUSNextTests.NativeComicTranslationTests "+name+"]' "+('failed' if name==probe.CORE[0] else 'passed') for name in probe.CORE))
            with self.assertRaises(SystemExit):probe.main(log,Path(root)/'out.json')

if __name__=='__main__':unittest.main()
